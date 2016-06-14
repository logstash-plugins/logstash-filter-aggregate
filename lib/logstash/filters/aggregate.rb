# encoding: utf-8

require "logstash/filters/base"
require "logstash/namespace"
require "thread"

# 
# The aim of this filter is to aggregate information available among several events (typically log lines) belonging to a same task,
# and finally push aggregated information into final task event.
#
# You should be very careful to set logstash filter workers to 1 (`-w 1` flag) for this filter to work 
# correctly otherwise documents
# may be processed out of sequence and unexpected results will occur.
# 
# ==== Example #1
# 
# * with these given logs :  
# [source,ruby]
# ----------------------------------
#  INFO - 12345 - TASK_START - start
#  INFO - 12345 - SQL - sqlQuery1 - 12
#  INFO - 12345 - SQL - sqlQuery2 - 34
#  INFO - 12345 - TASK_END - end
# ----------------------------------
# 
# * you can aggregate "sql duration" for the whole task with this configuration :
# [source,ruby]
# ----------------------------------
#  filter {
#    grok {
#      match => [ "message", "%{LOGLEVEL:loglevel} - %{NOTSPACE:taskid} - %{NOTSPACE:logger} - %{WORD:label}( - %{INT:duration:int})?" ]
#    }
#  
#    if [logger] == "TASK_START" {
#      aggregate {
#        task_id => "%{taskid}"
#        code => "map['sql_duration'] = 0"
#        map_action => "create"
#      }
#    }
# 
#    if [logger] == "SQL" {
#      aggregate {
#        task_id => "%{taskid}"
#        code => "map['sql_duration'] += event['duration']"
#        map_action => "update"
#      }
#    }
#  
#    if [logger] == "TASK_END" {
#      aggregate {
#        task_id => "%{taskid}"
#        code => "event['sql_duration'] = map['sql_duration']"
#        map_action => "update"
#        end_of_task => true
#        timeout => 120
#      }
#    }
#  }
# ----------------------------------
#
# * the final event then looks like :  
# [source,ruby]
# ----------------------------------
# {
#        "message" => "INFO - 12345 - TASK_END - end message",
#   "sql_duration" => 46
# }
# ----------------------------------
# 
# the field `sql_duration` is added and contains the sum of all sql queries durations.
# 
# ==== Example #2
# 
# * If you have the same logs than example #1, but without a start log :
# [source,ruby]
# ----------------------------------
#  INFO - 12345 - SQL - sqlQuery1 - 12
#  INFO - 12345 - SQL - sqlQuery2 - 34
#  INFO - 12345 - TASK_END - end
# ----------------------------------
# 
# * you can also aggregate "sql duration" with a slightly different configuration : 
# [source,ruby]
# ----------------------------------
#  filter {
#    grok {
#      match => [ "message", "%{LOGLEVEL:loglevel} - %{NOTSPACE:taskid} - %{NOTSPACE:logger} - %{WORD:label}( - %{INT:duration:int})?" ]
#    }
#     
#    if [logger] == "SQL" {
#      aggregate {
#        task_id => "%{taskid}"
#        code => "map['sql_duration'] ||= 0 ; map['sql_duration'] += event['duration']"
#      }
#    }
#     
#    if [logger] == "TASK_END" {
#      aggregate {
#        task_id => "%{taskid}"
#        code => "event['sql_duration'] = map['sql_duration']"
#        end_of_task => true
#        timeout => 120
#      }
#    }
#  }
# ----------------------------------
#
# * the final event is exactly the same than example #1
# * the key point is the "||=" ruby operator. It allows to initialize 'sql_duration' map entry to 0 only if this map entry is not already initialized
#
#
# ==== How it works
# * the filter needs a "task_id" to correlate events (log lines) of a same task
# * at the task beggining, filter creates a map, attached to task_id
# * for each event, you can execute code using 'event' and 'map' (for instance, copy an event field to map)
# * in the final event, you can execute a last code (for instance, add map data to final event)
# * after the final event, the map attached to task is deleted
# * in one filter configuration, it is recommanded to define a timeout option to protect the feature against unterminated tasks. It tells the filter to delete expired maps
# * if no timeout is defined, by default, all maps older than 1800 seconds are automatically deleted
# * finally, if `code` execution raises an exception, the error is logged and event is tagged '_aggregateexception'
#
#
# ==== Use Cases
# * extract some cool metrics from task logs and push them into task final log event (like in example #1 and #2)
# * extract error information in any task log line, and push it in final task event (to get a final document with all error information if any)
# * extract all back-end calls as a list, and push this list in final task event (to get a task profile)
# * extract all http headers logged in several lines to push this list in final task event (complete http request info)
# * for every back-end call, collect call details available on several lines, analyse it and finally tag final back-end call log line (error, timeout, business-warning, ...)
# * Finally, task id can be any correlation id matching your need : it can be a session id, a file path, ...
#
#
class LogStash::Filters::Aggregate < LogStash::Filters::Base

  config_name "aggregate"

  # The expression defining task ID to correlate logs.
  #
  # This value must uniquely identify the task in the system.
  #
  # Example value : "%{application}%{my_task_id}"
  config :task_id, :validate => :string, :required => true

  # The code to execute to update map, using current event.
  #
  # Or on the contrary, the code to execute to update event, using current map.
  #
  # You will have a 'map' variable and an 'event' variable available (that is the event itself).
  #
  # Example value : `"map['sql_duration'] += event['duration']"`
  config :code, :validate => :string, :required => true



  # The code to execute to update map, using a new event created on timeout.
  # If this code is not set, no event will be created
  #
  # Or on the contrary, the code to execute to update event, using current map.
  #
  # You will have a 'map' variable and an 'event' variable available (that is the event itself).
  #
  # Example value : `"map['sql_duration'] += event['duration']"`
  config :timeout_code, :validate => :string, :required => false


  # Timeout identifier to be used as the key mapping. The timeout event will have the task_id associated with this
  # identifier
  #
  # Example:
  #
  # If the taskId is "12345" and this field is set to "my_Id", the generated event will have:
  # event[ "my_Id" ] = "12345"
  #
  # Default value: "task_id"
  config :timeout_id, :validate => :string, :default => "task_id"


  # Tell the filter what to do with aggregate map.
  #
  # `create`: create the map, and execute the code only if map wasn't created before
  #
  # `update`: doesn't create the map, and execute the code only if map was created before
  #
  # `create_or_update`: create the map if it wasn't created before, execute the code in all cases
  config :map_action, :validate => :string, :default => "create_or_update"

  # Tell the filter that task is ended, and therefore, to delete map after code execution.  
  config :end_of_task, :validate => :boolean, :default => false

  # The amount of seconds after a task "end event" can be considered lost.
  #
  # When timeout occurs for a task, The task "map" is evicted.
  #
  # If no timeout is defined, default timeout will be applied : 1800 seconds.
  config :timeout, :validate => :number, :required => false

  # The path to file where aggregate maps are stored when logstash stops
  # and are loaded from when logstash starts.
  #
  # If not defined, aggregate maps will not be stored at logstash stop and will be lost. 
  # Must be defined in only one aggregate filter (as aggregate maps are global).
  #
  # Example value : `"/path/to/.aggregate_maps"`
  config :aggregate_maps_path, :validate => :string, :required => false
  
  
  # Default timeout (in seconds) when not defined in plugin configuration
  DEFAULT_TIMEOUT = 1800

  # This is the state of the filter.
  # For each entry, key is "task_id" and value is a map freely updatable by 'code' config
  @@aggregate_maps = {}

  # Mutex used to synchronize access to 'aggregate_maps'
  @@mutex = Mutex.new

  # Aggregate instance which will evict all zombie Aggregate elements (older than timeout)
  @@eviction_instance = nil

  # last time where eviction was launched
  @@last_eviction_timestamp = nil

  # flag indicating if aggregate_maps_path option has been already set on one aggregate instance
  @@aggregate_maps_path_set = false

  
  # Initialize plugin
  public
  def register
    # process lambda expression to call in each filter call
    eval("@codeblock = lambda { |event, map| #{@code} }", binding, "(aggregate filter code)")

    if @timeout_code
      eval("@timeout_codeblock = lambda { |event, map| #{@timeout_code} }", binding, "(aggregate filter timeout code)")
    end

    @@mutex.synchronize do
      # define eviction_instance
      if (!@timeout.nil? && (@@eviction_instance.nil? || @timeout < @@eviction_instance.timeout))
        @@eviction_instance = self
        @logger.info("Aggregate, timeout: #{@timeout} seconds")
      end

      # check if aggregate_maps_path option has already been set on another instance
      if (!@aggregate_maps_path.nil?)
        if (@@aggregate_maps_path_set)
          @@aggregate_maps_path_set = false
          raise LogStash::ConfigurationError, "Option 'aggregate_maps_path' must be set on only one aggregate filter"
        else
          @@aggregate_maps_path_set = true
        end
      end
      
      # load aggregate maps from file (if option defined)
      if (!@aggregate_maps_path.nil? && File.exist?(@aggregate_maps_path))
        File.open(@aggregate_maps_path, "r") { |from_file| @@aggregate_maps = Marshal.load(from_file) }
        File.delete(@aggregate_maps_path)
        @logger.info("Aggregate, load aggregate maps from : #{@aggregate_maps_path}")
      end
    end
  end

  # Called when logstash stops
  public
  def close

    # Protection against logstash reload
    @@aggregate_maps_path_set = false if @@aggregate_maps_path_set
    @@eviction_instance = nil unless @@eviction_instance.nil?

    @@mutex.synchronize do
      # store aggregate maps to file (if option defined)
      if (!@aggregate_maps_path.nil? && !@@aggregate_maps.empty?)
        File.open(@aggregate_maps_path, "w"){ |to_file| Marshal.dump(@@aggregate_maps, to_file) }
        @@aggregate_maps.clear()
        @logger.info("Aggregate, store aggregate maps to : #{@aggregate_maps_path}")
      end
    end
  end
  
  # This method is invoked each time an event matches the filter
  public
  def filter(event)

    # define task id
    task_id = event.sprintf(@task_id)
    return if task_id.nil? || task_id == @task_id

    noError = false

    # protect aggregate_maps against concurrent access, using a mutex
    @@mutex.synchronize do
    
      # retrieve the current aggregate map
      aggregate_maps_element = @@aggregate_maps[task_id]
      
      if (aggregate_maps_element.nil?)
        return if @map_action == "update"
        aggregate_maps_element = LogStash::Filters::Aggregate::Element.new(Time.now);
        @@aggregate_maps[task_id] = aggregate_maps_element
      else
        return if @map_action == "create"
      end
      map = aggregate_maps_element.map

      # execute the code to read/update map and event
      begin
        @codeblock.call(event, map)
        aggregate_maps_element.last_modified = Time.now
        noError = true
      rescue => exception
        @logger.error("Aggregate exception occurred. Error: #{exception} ; Code: #{@code} ; Map: #{map} ; EventData: #{event.instance_variable_get('@data')}")
        event.tag("_aggregateexception")
      end
      
      # delete the map if task is ended
      @@aggregate_maps.delete(task_id) if @end_of_task
    end

    # match the filter, only if no error occurred
    filter_matched(event) if noError
  end

  # Necessary to indicate logstash to periodically call 'flush' method
  def periodic_flush
    true
  end
  
  # This method is invoked by LogStash every 5 seconds.
  def flush(options = {})
    # Protection against no timeout defined by logstash conf : define a default eviction instance with timeout = DEFAULT_TIMEOUT seconds
    if (@@eviction_instance.nil?)
      @@eviction_instance = self
      @timeout = DEFAULT_TIMEOUT
    end
    
    # Launch eviction only every interval of (@timeout / 2) seconds
    if (@@eviction_instance == self && (@@last_eviction_timestamp.nil? || Time.now > @@last_eviction_timestamp + @timeout / 2))
      exipredEvents = remove_expired_elements()
      @@last_eviction_timestamp = Time.now
      return exipredEvents
    end
  end

  
  # Remove the expired Aggregate elements from "aggregate_maps" if they are older than timeout
  def remove_expired_elements()
    min_timestamp = Time.now - @timeout
    @@mutex.synchronize do
      events = []
      deleted = {}
      @@aggregate_maps.delete_if { |key, element| element.last_modified < min_timestamp ? deleted[key] = element : false}

      if @timeout_code and deleted.size > 0
        
        deleted.each { |key, value| 
          event = LogStash::Event.new
          event[@timeout_id] = key
          event['creation_timestamp'] = value.creation_timestamp
          map = value.map

           # execute the code to read/update map and event
          begin
            @timeout_codeblock.call(event, map)
            noError = true
          rescue => exception
            puts "Exception"
            @logger.error("Aggregate exception occurred. Error: #{exception} ; Code: #{@code} ; Map: #{map} ; EventData: #{event.instance_variable_get('@data')}")
            event.tag("_aggregateexception")
          end       

          events << event          
        }

        return events
      end
        return nil
    end
  end

end # class LogStash::Filters::Aggregate

# Element of "aggregate_maps"
class LogStash::Filters::Aggregate::Element

  attr_accessor :creation_timestamp, :map, :last_modified

  def initialize(creation_timestamp)
    @creation_timestamp = creation_timestamp
    @last_modified = creation_timestamp
    @map = {}
  end
end