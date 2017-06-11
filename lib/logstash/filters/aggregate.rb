# encoding: utf-8

require "logstash/filters/base"
require "logstash/namespace"
require "thread"
require "logstash/util/decorators"

#
# The aim of this filter is to aggregate information available among several events (typically log lines) belonging to a same task,
# and finally push aggregated information into final task event.
#
# You should be very careful to set Logstash filter workers to 1 (`-w 1` flag) for this filter to work correctly
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
#        code => "map['sql_duration'] += event.get('duration')"
#        map_action => "update"
#      }
#    }
#
#    if [logger] == "TASK_END" {
#      aggregate {
#        task_id => "%{taskid}"
#        code => "event.set('sql_duration', map['sql_duration'])"
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
#        code => "map['sql_duration'] ||= 0 ; map['sql_duration'] += event.get('duration')"
#      }
#    }
#
#    if [logger] == "TASK_END" {
#      aggregate {
#        task_id => "%{taskid}"
#        code => "event.set('sql_duration', map['sql_duration'])"
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
#     timeout_tags => ['_aggregatetimeout']
#     timeout_code => "event.set('several_clicks', event.get('clicks') > 1)"
#   }
# }
# ----------------------------------
#
# * After ten minutes, this will yield an event like:
#
# [source,json]
# ----------------------------------
# {
#   "user_id": "12345",
#   "clicks": 3,
#   "several_clicks": true,
#     "tags": [
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
#   { "country_name": "France", "towns": [ {"town_name": "Paris"}, {"town_name": "Marseille"} ] }
#   { "country_name": "USA", "towns": [ {"town_name": "New-York"} ] }
# ----------------------------------
# * You can do that using `push_previous_map_as_event` aggregate plugin option :
# [source,ruby]
# ----------------------------------
#    filter {
#      aggregate {
#        task_id => "%{country_name}"
#        code => "
#          map['country_name'] = event.get('country_name')
#          map['towns'] ||= []
#          map['towns'] << {'town_name' => event.get('town_name')}
#          event.cancel()
#        "
#        push_previous_map_as_event => true
#        timeout => 3
#      }
#    }
# ----------------------------------
# * The key point is that each time aggregate plugin detects a new `country_name`, it pushes previous aggregate map as a new Logstash event, and then creates a new empty map for the next country
# * When 5s timeout comes, the last aggregate map is pushed as a new event
# * Finally, initial events (which are not aggregated) are dropped because useless (thanks to `event.cancel()`)
#
#
# ==== Example #5 : no end event and push events as soon as possible
#
# Fifth use case: like example #3, there is no end event. Events keep comming for an indefinite time and you want to push the aggregation map as soon as possible after the last user interaction without waiting for the `timeout`. This allows to have the aggregated events pushed closer to real time.
#
# A typical case is aggregating or tracking user behaviour. We can track a user by its ID through the events, however once the user stops interacting, the events stop coming in. There is no specific event indicating the end of the user's interaction. The user ineraction will be considered as ended when no events for the specified user (task_id) arrive after the specified inactivity_timeout`.
#
# If the user continues interacting for longer than `timeout` seconds (since first event), the aggregation map will still be deleted and pushed as a new event when timeout occurs.
#
# The difference with example #3 is that the events will be pushed as soon as the user stops interacting for `inactivity_timeout` seconds instead of waiting for the end of `timeout` seconds since first event.
#
# In this case, we can enable the option 'push_map_as_event_on_timeout' to enable pushing the aggregation map as a new event when inactivity timeout occurs.
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
#     timeout => 3600 # 1 hour timeout, user activity will be considered finished one hour after the first event, even if events keep comming
#     inactivity_timeout => 300 # 5 minutes timeout, user activity will be considered finished if no new events arrive 5 minutes after the last event
#     timeout_tags => ['_aggregatetimeout']
#     timeout_code => "event.set('several_clicks', event.get('clicks') > 1)"
#   }
# }
# ----------------------------------
#
# * After five minutes of inactivity or one hour since first event, this will yield an event like:
#
# [source,json]
# ----------------------------------
# {
#   "user_id": "12345",
#   "clicks": 3,
#   "several_clicks": true,
#     "tags": [
#        "_aggregatetimeout"
#     ]
# }
# ----------------------------------
#
#
# ==== How it works
# * the filter needs a "task_id" to correlate events (log lines) of a same task
# * at the task beggining, filter creates a map, attached to task_id
# * for each event, you can execute code using 'event' and 'map' (for instance, copy an event field to map)
# * in the final event, you can execute a last code (for instance, add map data to final event)
# * after the final event, the map attached to task is deleted (thanks to `end_of_task => true`)
# * an aggregate map is tied to one task_id value which is tied to one task_id pattern. So if you have 2 filters with different task_id patterns, even if you have same task_id value, they won't share the same aggregate map.
# * in one filter configuration, it is recommanded to define a timeout option to protect the feature against unterminated tasks. It tells the filter to delete expired maps
# * if no timeout is defined, by default, all maps older than 1800 seconds are automatically deleted
# * all timeout options have to be defined in only one aggregate filter per task_id pattern. Timeout options are : timeout, inactivity_timeout,timeout_code, push_map_as_event_on_timeout, push_previous_map_as_event, timeout_task_id_field, timeout_tags
# * if `code` execution raises an exception, the error is logged and event is tagged '_aggregateexception'
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


  # ############## #
  # CONFIG OPTIONS #
  # ############## #


  config_name "aggregate"

  # The expression defining task ID to correlate logs.
  #
  # This value must uniquely identify the task.
  #
  # Example:
  # [source,ruby]
  #     filter {
  #       aggregate {
  #         task_id => "%{type}%{my_task_id}"
  #       }
  #     }
  config :task_id, :validate => :string, :required => true

  # The code to execute to update map, using current event.
  #
  # Or on the contrary, the code to execute to update event, using current map.
  #
  # You will have a 'map' variable and an 'event' variable available (that is the event itself).
  #
  # Example:
  # [source,ruby]
  #     filter {
  #       aggregate {
  #         code => "map['sql_duration'] += event.get('duration')"
  #       }
  #     }
  config :code, :validate => :string, :required => true

  # Tell the filter what to do with aggregate map.
  #
  # `"create"`: create the map, and execute the code only if map wasn't created before
  #
  # `"update"`: doesn't create the map, and execute the code only if map was created before
  #
  # `"create_or_update"`: create the map if it wasn't created before, execute the code in all cases
  config :map_action, :validate => :string, :default => "create_or_update"

  # Tell the filter that task is ended, and therefore, to delete aggregate map after code execution.
  config :end_of_task, :validate => :boolean, :default => false

  # The path to file where aggregate maps are stored when Logstash stops
  # and are loaded from when Logstash starts.
  #
  # If not defined, aggregate maps will not be stored at Logstash stop and will be lost.
  # Must be defined in only one aggregate filter (as aggregate maps are global).
  #
  # Example:
  # [source,ruby]
  #     filter {
  #       aggregate {
  #         aggregate_maps_path => "/path/to/.aggregate_maps"
  #       }
  #     }
  config :aggregate_maps_path, :validate => :string, :required => false

  # The amount of seconds (since the first event) after which a task is considered as expired.
  #
  # When timeout occurs for a task, its aggregate map is evicted.
  #
  # If 'push_map_as_event_on_timeout' or 'push_previous_map_as_event' is set to true, the task aggregation map is pushed as a new Logstash event.
  #
  # Timeout can be defined for each "task_id" pattern.
  #
  # If no timeout is defined, default timeout will be applied : 1800 seconds.
  config :timeout, :validate => :number, :required => false

  # The amount of seconds (since the last event) after which a task is considered as expired.
  #
  # When timeout occurs for a task, its aggregate map is evicted.
  #
  # If 'push_map_as_event_on_timeout' or 'push_previous_map_as_event' is set to true, the task aggregation map is pushed as a new Logstash event.
  #
  # `inactivity_timeout` can be defined for each "task_id" pattern.
  #
  # `inactivity_timeout` must be lower than `timeout`.
  #
  # If no `inactivity_timeout` is defined, no inactivity timeout will be applied (only timeout will be applied).
  config :inactivity_timeout, :validate => :number, :required => false

  # The code to execute to complete timeout generated event, when 'push_map_as_event_on_timeout' or 'push_previous_map_as_event' is set to true.
  # The code block will have access to the newly generated timeout event that is pre-populated with the aggregation map.
  #
  # If `'timeout_task_id_field'` is set, the event is also populated with the task_id value
  #
  # Example:
  # [source,ruby]
  #     filter {
  #       aggregate {
  #         timeout_code => "event.set('state', 'timeout')"
  #       }
  #     }
  config :timeout_code, :validate => :string, :required => false

  # When this option is enabled, each time a task timeout is detected, it pushes task aggregation map as a new Logstash event.
  # This enables to detect and process task timeouts in Logstash, but also to manage tasks that have no explicit end event.
  config :push_map_as_event_on_timeout, :validate => :boolean, :required => false, :default => false

  # When this option is enabled, each time aggregate plugin detects a new task id, it pushes previous aggregate map as a new Logstash event,
  # and then creates a new empty map for the next task.
  #
  # WARNING: this option works fine only if tasks come one after the other. It means : all task1 events, then all task2 events, etc...
  config :push_previous_map_as_event, :validate => :boolean, :required => false, :default => false

  # This option indicates the timeout generated event's field for the "task_id" value.
  # The task id will then be set into the timeout event. This can help correlate which tasks have been timed out.
  #
  # For example, with option `timeout_task_id_field => "my_id"` ,when timeout task id is `"12345"`, the generated timeout event will contain `'my_id' => '12345'`.
  #
  # By default, if this option is not set, task id value won't be set into timeout generated event.
  config :timeout_task_id_field, :validate => :string, :required => false

  # Defines tags to add when a timeout event is generated and yield
  #
  # Example:
  # [source,ruby]
  #     filter {
  #       aggregate {
  #         timeout_tags => ["aggregate_timeout']
  #       }
  #     }
  config :timeout_tags, :validate => :array, :required => false, :default => []


  # ################ #
  # STATIC VARIABLES #
  # ################ #


  # Default timeout (in seconds) when not defined in plugin configuration
  DEFAULT_TIMEOUT = 1800

  # This is the state of the filter.
  # For each entry, key is "task_id" and value is a map freely updatable by 'code' config
  @@aggregate_maps = {}

  # Mutex used to synchronize access to 'aggregate_maps'
  @@mutex = Mutex.new

  # Default timeout for task_id patterns where timeout is not defined in Logstash filter configuration
  @@default_timeout = nil

  # For each "task_id" pattern, defines which Aggregate instance will process flush() call, processing expired Aggregate elements (older than timeout)
  # For each entry, key is "task_id pattern" and value is "aggregate instance"
  @@flush_instance_map = {}

  # last time where timeout management in flush() method was launched, per "task_id" pattern
  @@last_flush_timestamp_map = {}

  # flag indicating if aggregate_maps_path option has been already set on one aggregate instance
  @@aggregate_maps_path_set = false

  # defines which Aggregate instance will close Aggregate static variables
  @@static_close_instance = nil


  # ####### #
  # METHODS #
  # ####### #


  # Initialize plugin
  public
  def register

    @logger.debug("Aggregate register call", :code => @code)

    # validate task_id option
    if !@task_id.match(/%\{.+\}/)
      raise LogStash::ConfigurationError, "Aggregate plugin: task_id pattern '#{@task_id}' must contain a dynamic expression like '%{field}'"
    end

    # process lambda expression to call in each filter call
    eval("@codeblock = lambda { |event, map| #{@code} }", binding, "(aggregate filter code)")

    # process lambda expression to call in the timeout case or previous event case
    if @timeout_code
      eval("@timeout_codeblock = lambda { |event| #{@timeout_code} }", binding, "(aggregate filter timeout code)")
    end

    @@mutex.synchronize do

      # timeout management : define eviction_instance for current task_id pattern
      if has_timeout_options?
        if @@flush_instance_map.has_key?(@task_id)
          # all timeout options have to be defined in only one aggregate filter per task_id pattern
          raise LogStash::ConfigurationError, "Aggregate plugin: For task_id pattern '#{@task_id}', there are more than one filter which defines timeout options. All timeout options have to be defined in only one aggregate filter per task_id pattern. Timeout options are : #{display_timeout_options}"
        end
        @@flush_instance_map[@task_id] = self
        @logger.debug("Aggregate timeout for '#{@task_id}' pattern: #{@timeout} seconds")
      end

      # timeout management : define default_timeout
      if !@timeout.nil? && (@@default_timeout.nil? || @timeout < @@default_timeout)
        @@default_timeout = @timeout
        @logger.debug("Aggregate default timeout: #{@timeout} seconds")
      end

      # inactivity timeout management: make sure it is lower than timeout
      if !@inactivity_timeout.nil? && ((!@timeout.nil? && @inactivity_timeout > @timeout) || (!@@default_timeout.nil? && @inactivity_timeout > @@default_timeout))
        raise LogStash::ConfigurationError, "Aggregate plugin: For task_id pattern #{@task_id}, inactivity_timeout must be lower than timeout"
      end

      # reinit static_close_instance (if necessary)
      if !@@aggregate_maps_path_set && !@@static_close_instance.nil?
        @@static_close_instance = nil
      end

      # check if aggregate_maps_path option has already been set on another instance else set @@aggregate_maps_path_set
      if !@aggregate_maps_path.nil?
        if @@aggregate_maps_path_set
          @@aggregate_maps_path_set = false
          raise LogStash::ConfigurationError, "Aggregate plugin: Option 'aggregate_maps_path' must be set on only one aggregate filter"
        else
          @@aggregate_maps_path_set = true
          @@static_close_instance = self
        end
      end

      # load aggregate maps from file (if option defined)
      if !@aggregate_maps_path.nil? && File.exist?(@aggregate_maps_path)
        File.open(@aggregate_maps_path, "r") { |from_file| @@aggregate_maps.merge!(Marshal.load(from_file)) }
        File.delete(@aggregate_maps_path)
        @logger.info("Aggregate maps loaded from : #{@aggregate_maps_path}")
      end

      # init aggregate_maps
      @@aggregate_maps[@task_id] ||= {}
    end
  end

  # Called when Logstash stops
  public
  def close

    @logger.debug("Aggregate close call", :code => @code)

    # define static close instance if none is already defined
    @@static_close_instance = self if @@static_close_instance.nil?

    if @@static_close_instance == self
      # store aggregate maps to file (if option defined)
      @@mutex.synchronize do
        @@aggregate_maps.delete_if { |key, value| value.empty? }
        if !@aggregate_maps_path.nil? && !@@aggregate_maps.empty?
          File.open(@aggregate_maps_path, "w"){ |to_file| Marshal.dump(@@aggregate_maps, to_file) }
          @logger.info("Aggregate maps stored to : #{@aggregate_maps_path}")
        end
        @@aggregate_maps.clear()
      end

      # reinit static variables for Logstash reload
      @@default_timeout = nil
      @@flush_instance_map = {}
      @@last_flush_timestamp_map = {}
      @@aggregate_maps_path_set = false
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
      aggregate_maps_element = @@aggregate_maps[@task_id][task_id]


      # create aggregate map, if it doesn't exist
      if aggregate_maps_element.nil?
        return if @map_action == "update"
        # create new event from previous map, if @push_previous_map_as_event is enabled
        if @push_previous_map_as_event && !@@aggregate_maps[@task_id].empty?
          event_to_yield = extract_previous_map_as_event()
        end
        aggregate_maps_element = LogStash::Filters::Aggregate::Element.new(Time.now);
        @@aggregate_maps[@task_id][task_id] = aggregate_maps_element
      else
        return if @map_action == "create"
      end
      map = aggregate_maps_element.map
      # update last event timestamp
      aggregate_maps_element.lastevent_timestamp = Time.now
      # execute the code to read/update map and event
      begin
        @codeblock.call(event, map)
        @logger.debug("Aggregate successful filter code execution", :code => @code)
        noError = true
      rescue => exception
        @logger.error("Aggregate exception occurred",
                      :error => exception,
                      :code => @code,
                      :map => map,
                      :event_data => event.to_hash_with_metadata)
        event.tag("_aggregateexception")
      end

      # delete the map if task is ended
      @@aggregate_maps[@task_id].delete(task_id) if @end_of_task

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

    @logger.debug("Aggregate create_timeout_event call with task_id '#{task_id}'")

    event_to_yield = LogStash::Event.new(aggregation_map)

    if @timeout_task_id_field
      event_to_yield.set(@timeout_task_id_field, task_id)
    end

    LogStash::Util::Decorators.add_tags(@timeout_tags, event_to_yield, "filters/#{self.class.name}")

    # Call code block if available
    if @timeout_code
      begin
        @timeout_codeblock.call(event_to_yield)
      rescue => exception
        @logger.error("Aggregate exception occurred",
                      :error => exception,
                      :timeout_code => @timeout_code,
                      :timeout_event_data => event_to_yield.to_hash_with_metadata)
        event_to_yield.tag("_aggregateexception")
      end
    end

    return event_to_yield
  end

  # Extract the previous map in aggregate maps, and return it as a new Logstash event
  def extract_previous_map_as_event
    previous_entry = @@aggregate_maps[@task_id].shift()
    previous_task_id = previous_entry[0]
    previous_map = previous_entry[1].map
    return create_timeout_event(previous_map, previous_task_id)
  end

  # Necessary to indicate Logstash to periodically call 'flush' method
  def periodic_flush
    true
  end

  # This method is invoked by LogStash every 5 seconds.
  def flush(options = {})

    @logger.debug("Aggregate flush call with #{options}")

    # Protection against no timeout defined by Logstash conf : define a default eviction instance with timeout = DEFAULT_TIMEOUT seconds
    if @@default_timeout.nil?
      @@default_timeout = DEFAULT_TIMEOUT
    end
    if !@@flush_instance_map.has_key?(@task_id)
      @@flush_instance_map[@task_id] = self
      @timeout = @@default_timeout
    elsif @@flush_instance_map[@task_id].timeout.nil?
      @@flush_instance_map[@task_id].timeout = @@default_timeout
    end

    if @@flush_instance_map[@task_id].inactivity_timeout.nil?
      @@flush_instance_map[@task_id].inactivity_timeout = @@flush_instance_map[@task_id].timeout
    end

    # Launch timeout management only every interval of (@inactivity_timeout / 2) seconds or at Logstash shutdown
    if @@flush_instance_map[@task_id] == self && (!@@last_flush_timestamp_map.has_key?(@task_id) || Time.now > @@last_flush_timestamp_map[@task_id] + @inactivity_timeout / 2 || options[:final])
      events_to_flush = remove_expired_maps()

      # at Logstash shutdown, if push_previous_map_as_event is enabled, it's important to force flush (particularly for jdbc input plugin)
      if options[:final] && @push_previous_map_as_event && !@@aggregate_maps[@task_id].empty?
        events_to_flush << extract_previous_map_as_event()
      end

      # tag flushed events, indicating "final flush" special event
      if options[:final]
        events_to_flush.each { |event_to_flush| event_to_flush.tag("_aggregatefinalflush") }
      end

      # update last flush timestamp
      @@last_flush_timestamp_map[@task_id] = Time.now

      # return events to flush into Logstash pipeline
      return events_to_flush
    else
      return []
    end

  end


  # Remove the expired Aggregate maps from @@aggregate_maps if they are older than timeout or if no new event has been received since inactivity_timeout.
  # If @push_previous_map_as_event option is set, or @push_map_as_event_on_timeout is set, expired maps are returned as new events to be flushed to Logstash pipeline.
  def remove_expired_maps()
    events_to_flush = []
    min_timestamp = Time.now - @timeout
    min_inactivity_timestamp = Time.now - @inactivity_timeout

    @@mutex.synchronize do

      @logger.debug("Aggregate remove_expired_maps call with '#{@task_id}' pattern and #{@@aggregate_maps[@task_id].length} maps")

      @@aggregate_maps[@task_id].delete_if do |key, element|
        if element.creation_timestamp < min_timestamp || element.lastevent_timestamp < min_inactivity_timestamp
          if @push_previous_map_as_event || @push_map_as_event_on_timeout
            events_to_flush << create_timeout_event(element.map, key)
          end
          next true
        end
        next false
      end
    end

    return events_to_flush
  end

  # return if this filter instance has any timeout option enabled in logstash configuration
  def has_timeout_options?()
    return (
      timeout ||
      inactivity_timeout ||
      timeout_code ||
      push_map_as_event_on_timeout ||
      push_previous_map_as_event ||
      timeout_task_id_field ||
      !timeout_tags.empty?
    )
  end

  # display all possible timeout options
  def display_timeout_options()
    return [
      "timeout",
      "inactivity_timeout",
      "timeout_code",
      "push_map_as_event_on_timeout",
      "push_previous_map_as_event",
      "timeout_task_id_field",
      "timeout_tags"
    ].join(", ")
  end

end # class LogStash::Filters::Aggregate

# Element of "aggregate_maps"
class LogStash::Filters::Aggregate::Element

  attr_accessor :creation_timestamp, :lastevent_timestamp, :map

  def initialize(creation_timestamp)
    @creation_timestamp = creation_timestamp
    @lastevent_timestamp = creation_timestamp
    @map = {}
  end
end
