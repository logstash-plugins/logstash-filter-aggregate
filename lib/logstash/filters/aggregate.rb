# encoding: utf-8

require "logstash/filters/base"
require "logstash/namespace"
require "thread"

# 
# The aim of this filter is to aggregate information available among several events (typically log lines) belonging to a same task,
# and finally push aggregated information into final task event.
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
  # Example value : "map['sql_duration'] += event['duration']"
  config :code, :validate => :string, :required => true

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
  # The task "map" is evicted.
  #
  # Default value (`0`) means no timeout so no auto eviction.
  config :timeout, :validate => :number, :required => false, :default => 0

  
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

  # Initialize plugin
  public
  def register
    # process lambda expression to call in each filter call
    eval("@codeblock = lambda { |event, map| #{@code} }", binding, "(aggregate filter code)")

    # define eviction_instance
    @@mutex.synchronize do
      if (@timeout > 0 && (@@eviction_instance.nil? || @timeout < @@eviction_instance.timeout))
        @@eviction_instance = self
        @logger.info("Aggregate, timeout: #{@timeout} seconds")
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
      remove_expired_elements()
      @@last_eviction_timestamp = Time.now
    end
    
    return nil
  end

  
  # Remove the expired Aggregate elements from "aggregate_maps" if they are older than timeout
  def remove_expired_elements()
    min_timestamp = Time.now - @timeout
    @@mutex.synchronize do
      @@aggregate_maps.delete_if { |key, element| element.creation_timestamp < min_timestamp }
    end
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
