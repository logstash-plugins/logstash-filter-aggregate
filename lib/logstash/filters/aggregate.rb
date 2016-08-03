# encoding: utf-8

require "logstash/filters/base"
require "logstash/namespace"
require "thread"

# 
# The aim of this filter is to aggregate information available among several events (typically log lines) belonging to a same task,
# and finally push aggregated information into final task event.
#
# You should be very careful to set logstash filter workers to 1 (`-w 1` flag) for this filter to work correctly 
# otherwise events may be processed out of sequence and unexpected results will occur.
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
# ==== Example #2 : no start event
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
# ==== Example #3 : no end event
#
# Third use case: You have no specific end event. 
#
# A typical case is aggregating or tracking user behaviour. We can track a user by its ID through the events, however once the user stops interacting, the events stop coming in. There is no specific event indicating the end of the user's interaction.
#
# In this case, we can enable the option 'push_map_as_event_on_timeout' to enable pushing the aggregation map as a new event when a timeout occurs.  
# In addition, we can enable 'timeout_code' to execute code on the populated timeout event.
# We can also add 'timeout_task_id_field' so we can correlate the task_id, which in this case would be the user's ID. 
#
# * Given these logs: 
#
# [source,ruby]
# ----------------------------------
# INFO - 12345 - Clicked One
# INFO - 12345 - Clicked Two
# INFO - 12345 - Clicked Three
# ----------------------------------
#
# * You can aggregate the amount of clicks the user did like this:
# 
# [source,ruby]
# ----------------------------------
# filter {
#   grok {
#     match => [ "message", "%{LOGLEVEL:loglevel} - %{NOTSPACE:user_id} - %{GREEDYDATA:msg_text}" ]
#   }
#
#   aggregate {
#     task_id => "%{user_id}"
#     code => "map['clicks'] ||= 0; map['clicks'] += 1;"
#     push_map_as_event_on_timeout => true
#     timeout_task_id_field => "user_id"
#     timeout => 600 # 10 minutes timeout
#     timeout_code => "event.tag('_aggregatetimeout')"
#   }
# }
# ----------------------------------
#
# * After ten minutes, this will yield an event like:
#
# [source,json]
# ----------------------------------
# {
#   "user_id" : "12345",
#   "clicks" : 3,
#     "tags" : [
#        "_aggregatetimeout"
#     ]
# }
# ----------------------------------
#
# ==== Example #4 : no end event and tasks come one after the other
# 
# Fourth use case : like example #3, you have no specific end event, but also, tasks come one after the other.  
# That is to say : tasks are not interlaced. All task1 events come, then all task2 events come, ...  
# In that case, you don't want to wait task timeout to flush aggregation map.  
# * A typical case is aggregating results from jdbc input plugin.  
# * Given that you have this SQL query : `SELECT country_name, town_name FROM town`  
# * Using jdbc input plugin, you get these 3 events from :
# [source,json]
# ----------------------------------
#   { "country_name": "France", "town_name": "Paris" }
#   { "country_name": "France", "town_name": "Marseille" }
#   { "country_name": "USA", "town_name": "New-York" }
# ----------------------------------
# * And you would like these 2 result events to push them into elasticsearch :
# [source,json]
# ----------------------------------
#   { "country_name": "France", "town_name": [ "Paris", "Marseille" ] }
#   { "country_name": "USA", "town_name": [ "New-York" ] }
# ----------------------------------
# * You can do that using `push_previous_map_as_event` aggregate plugin option :
# [source,ruby]
# ----------------------------------
#      filter {
#      aggregate {
#          task_id => "%{country_name}"
#          code => "
#           map['tags'] ||= ['aggregated']
#           map['town_name'] ||= []
#           event.to_hash.each do |key,value|
#             map[key] = value unless map.has_key?(key)
#             map[key] << value if map[key].is_a?(Array)
#           end
#          "
#          push_previous_map_as_event => true
#          timeout => 5
#      }
# 
#      if "aggregated" not in [tags] {
#       drop {}
#      }
#    }
# ----------------------------------
# * The key point is that each time aggregate plugin detects a new `country_name`, it pushes previous aggregate map as a new logstash event (with 'aggregated' tag), and then creates a new empty map for the next country
# * When 5s timeout comes, the last aggregate map is pushed as a new event
# * Finally, initial events (which are not aggregated) are dropped because useless
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
# * extract error information in any task log line, and push it in final task event (to get a final event with all error information if any)
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



  # The code to execute to complete timeout generated event, when 'push_map_as_event_on_timeout' or 'push_previous_map_as_event' is set to true. 
  # The code block will have access to the newly generated timeout event that is pre-populated with the aggregation map. 
  #
  # If 'timeout_task_id_field' is set, the event is also populated with the task_id value 
  #
  # Example value: `"event.tag('_aggregatetimeout')"`
  config :timeout_code, :validate => :string, :required => false


  # This option indicates the timeout generated event's field for the "task_id" value. 
  # The task id will then be set into the timeout event. This can help correlate which tasks have been timed out.  
  #
  # This field has no default value and will not be set on the event if not configured.
  #
  # Example:
  #
  # If the task_id is "12345" and this field is set to "my_id", the generated event will have:
  # event[ "my_id" ] = "12345"
  #
  config :timeout_task_id_field, :validate => :string, :required => false


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
  
  # When this option is enabled, each time aggregate plugin detects a new task id, it pushes previous aggregate map as a new logstash event, 
  # and then creates a new empty map for the next task.
  #
  # WARNING: this option works fine only if tasks come one after the other. It means : all task1 events, then all task2 events, etc...
  config :push_previous_map_as_event, :validate => :boolean, :required => false, :default => false
  
  # When this option is enabled, each time a task timeout is detected, it pushes task aggregation map as a new logstash event.  
  # This enables to detect and process task timeouts in logstash, but also to manage tasks that have no explicit end event.
  config :push_map_as_event_on_timeout, :validate => :boolean, :required => false, :default => false
  
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

    # process lambda expression to call in the timeout case or previous event case
    if @timeout_code
      eval("@timeout_codeblock = lambda { |event| #{@timeout_code} }", binding, "(aggregate filter timeout code)")
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
    event_to_yield = nil

    # protect aggregate_maps against concurrent access, using a mutex
    @@mutex.synchronize do
    
      # retrieve the current aggregate map
      aggregate_maps_element = @@aggregate_maps[task_id]
      

      # create aggregate map, if it doesn't exist
      if (aggregate_maps_element.nil?)
        return if @map_action == "update"
        # create new event from previous map, if @push_previous_map_as_event is enabled
        if (@push_previous_map_as_event and !@@aggregate_maps.empty?)
          previous_map = @@aggregate_maps.shift[1].map
          event_to_yield = create_timeout_event(previous_map, task_id)
        end
        aggregate_maps_element = LogStash::Filters::Aggregate::Element.new(Time.now);
        @@aggregate_maps[task_id] = aggregate_maps_element
      else
        return if @map_action == "create"
      end
      map = aggregate_maps_element.map

      # execute the code to read/update map and event
      begin
        @codeblock.call(event, map)
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

    # yield previous map as new event if set
    yield event_to_yield unless event_to_yield.nil?

  end

  # Create a new event from the aggregation_map and the corresponding task_id
  # This will create the event and
  #  if @timeout_task_id_field is set, it will set the task_id on the timeout event
  #  if @timeout_code is set, it will execute the timeout code on the created timeout event
  # returns the newly created event
  def create_timeout_event(aggregation_map, task_id)
    event_to_yield = LogStash::Event.new(aggregation_map)        

    if @timeout_task_id_field
      event_to_yield[@timeout_task_id_field] = task_id
    end

    # Call code block if available
    if @timeout_code
      begin
        @timeout_codeblock.call(event_to_yield)
      rescue => exception
        @logger.error("Aggregate exception occurred. Error: #{exception} ; TimeoutCode: #{@timeout_code} ; TimeoutEventData: #{event_to_yield.instance_variable_get('@data')}")
        event_to_yield.tag("_aggregateexception")
      end
    end
            
    return event_to_yield
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
      events_to_flush = remove_expired_maps()
      @@last_eviction_timestamp = Time.now
      return events_to_flush
    end

  end

  
  # Remove the expired Aggregate maps from @@aggregate_maps if they are older than timeout.
  # If @push_previous_map_as_event option is set, or @push_map_as_event_on_timeout is set, expired maps are returned as new events to be flushed to Logstash pipeline.
  def remove_expired_maps()
    events_to_flush = []
    min_timestamp = Time.now - @timeout
    
    @@mutex.synchronize do

      @@aggregate_maps.delete_if do |key, element| 
        if (element.creation_timestamp < min_timestamp)
          if (@push_previous_map_as_event) || (@push_map_as_event_on_timeout)
            events_to_flush << create_timeout_event(element.map, key)
          end
          next true
        end
        next false
      end
    end
    
    return events_to_flush
  end

end # class LogStash::Filters::Aggregate

# Element of "aggregate_maps"
class LogStash::Filters::Aggregate::Element

  attr_accessor :creation_timestamp, :map

  def initialize(creation_timestamp)
    @creation_timestamp = creation_timestamp
    @map = {}
  end
end