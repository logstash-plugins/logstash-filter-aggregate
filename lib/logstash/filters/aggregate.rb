# encoding: utf-8

require "logstash/filters/base"
require "logstash/namespace"
require "thread"
require "logstash/util/decorators"


class LogStash::Filters::Aggregate < LogStash::Filters::Base


  # ############## #
  # CONFIG OPTIONS #
  # ############## #


  config_name "aggregate"

  config :task_id, :validate => :string, :required => true

  config :code, :validate => :string, :required => true

  config :map_action, :validate => :string, :default => "create_or_update"

  config :end_of_task, :validate => :boolean, :default => false

  config :aggregate_maps_path, :validate => :string, :required => false

  config :timeout, :validate => :number, :required => false

  config :inactivity_timeout, :validate => :number, :required => false

  config :timeout_code, :validate => :string, :required => false

  config :push_map_as_event_on_timeout, :validate => :boolean, :required => false, :default => false

  config :push_previous_map_as_event, :validate => :boolean, :required => false, :default => false

  config :timeout_task_id_field, :validate => :string, :required => false

  config :timeout_tags, :validate => :array, :required => false, :default => []


  # ################## #
  # INSTANCE VARIABLES #
  # ################## #
  

  # pointer to current pipeline context
  attr_accessor :current_pipeline


  # ################ #
  # STATIC VARIABLES #
  # ################ #


  # Default timeout (in seconds) when not defined in plugin configuration
  DEFAULT_TIMEOUT = 1800
  
  # Store all shared aggregate attributes per pipeline id
  @@pipelines = {}


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

    # init pipeline context
    @@pipelines[pipeline_id] ||= LogStash::Filters::Aggregate::Pipeline.new();
    @current_pipeline = @@pipelines[pipeline_id]

    @current_pipeline.mutex.synchronize do

      # timeout management : define eviction_instance for current task_id pattern
      if has_timeout_options?
        if @current_pipeline.flush_instance_map.has_key?(@task_id)
          # all timeout options have to be defined in only one aggregate filter per task_id pattern
          raise LogStash::ConfigurationError, "Aggregate plugin: For task_id pattern '#{@task_id}', there are more than one filter which defines timeout options. All timeout options have to be defined in only one aggregate filter per task_id pattern. Timeout options are : #{display_timeout_options}"
        end
        @current_pipeline.flush_instance_map[@task_id] = self
        @logger.debug("Aggregate timeout for '#{@task_id}' pattern: #{@timeout} seconds")
      end

      # timeout management : define default_timeout
      if !@timeout.nil? && (@current_pipeline.default_timeout.nil? || @timeout < @current_pipeline.default_timeout)
        @current_pipeline.default_timeout = @timeout
        @logger.debug("Aggregate default timeout: #{@timeout} seconds")
      end

      # inactivity timeout management: make sure it is lower than timeout
      if !@inactivity_timeout.nil? && ((!@timeout.nil? && @inactivity_timeout > @timeout) || (!@current_pipeline.default_timeout.nil? && @inactivity_timeout > @current_pipeline.default_timeout))
        raise LogStash::ConfigurationError, "Aggregate plugin: For task_id pattern #{@task_id}, inactivity_timeout must be lower than timeout"
      end

      # reinit pipeline_close_instance (if necessary)
      if !@current_pipeline.aggregate_maps_path_set && !@current_pipeline.pipeline_close_instance.nil?
        @current_pipeline.pipeline_close_instance = nil
      end

      # check if aggregate_maps_path option has already been set on another instance else set @current_pipeline.aggregate_maps_path_set
      if !@aggregate_maps_path.nil?
        if @current_pipeline.aggregate_maps_path_set
          @current_pipeline.aggregate_maps_path_set = false
          raise LogStash::ConfigurationError, "Aggregate plugin: Option 'aggregate_maps_path' must be set on only one aggregate filter"
        else
          @current_pipeline.aggregate_maps_path_set = true
          @current_pipeline.pipeline_close_instance = self
        end
      end

      # load aggregate maps from file (if option defined)
      if !@aggregate_maps_path.nil? && File.exist?(@aggregate_maps_path)
        File.open(@aggregate_maps_path, "r") { |from_file| @current_pipeline.aggregate_maps.merge!(Marshal.load(from_file)) }
        File.delete(@aggregate_maps_path)
        @logger.info("Aggregate maps loaded from : #{@aggregate_maps_path}")
      end

      # init aggregate_maps
      @current_pipeline.aggregate_maps[@task_id] ||= {}
      
      
    end
  end

  # Called when Logstash stops
  public
  def close

    @logger.debug("Aggregate close call", :code => @code)

    # define pipeline close instance if none is already defined
    @current_pipeline.pipeline_close_instance = self if @current_pipeline.pipeline_close_instance.nil?

    if @current_pipeline.pipeline_close_instance == self
      # store aggregate maps to file (if option defined)
      @current_pipeline.mutex.synchronize do
        @current_pipeline.aggregate_maps.delete_if { |key, value| value.empty? }
        if !@aggregate_maps_path.nil? && !@current_pipeline.aggregate_maps.empty?
          File.open(@aggregate_maps_path, "w"){ |to_file| Marshal.dump(@current_pipeline.aggregate_maps, to_file) }
          @logger.info("Aggregate maps stored to : #{@aggregate_maps_path}")
        end
      end

      # remove pipeline context for Logstash reload
      @@pipelines.delete(pipeline_id)
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
    @current_pipeline.mutex.synchronize do

      # retrieve the current aggregate map
      aggregate_maps_element = @current_pipeline.aggregate_maps[@task_id][task_id]


      # create aggregate map, if it doesn't exist
      if aggregate_maps_element.nil?
        return if @map_action == "update"
        # create new event from previous map, if @push_previous_map_as_event is enabled
        if @push_previous_map_as_event && !@current_pipeline.aggregate_maps[@task_id].empty?
          event_to_yield = extract_previous_map_as_event()
        end
        aggregate_maps_element = LogStash::Filters::Aggregate::Element.new(Time.now);
        @current_pipeline.aggregate_maps[@task_id][task_id] = aggregate_maps_element
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
      @current_pipeline.aggregate_maps[@task_id].delete(task_id) if @end_of_task

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
    previous_entry = @current_pipeline.aggregate_maps[@task_id].shift()
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
    if @current_pipeline.default_timeout.nil?
      @current_pipeline.default_timeout = DEFAULT_TIMEOUT
    end
    if !@current_pipeline.flush_instance_map.has_key?(@task_id)
      @current_pipeline.flush_instance_map[@task_id] = self
      @timeout = @current_pipeline.default_timeout
    elsif @current_pipeline.flush_instance_map[@task_id].timeout.nil?
      @current_pipeline.flush_instance_map[@task_id].timeout = @current_pipeline.default_timeout
    end

    if @current_pipeline.flush_instance_map[@task_id].inactivity_timeout.nil?
      @current_pipeline.flush_instance_map[@task_id].inactivity_timeout = @current_pipeline.flush_instance_map[@task_id].timeout
    end

    # Launch timeout management only every interval of (@inactivity_timeout / 2) seconds or at Logstash shutdown
    if @current_pipeline.flush_instance_map[@task_id] == self && !@current_pipeline.aggregate_maps[@task_id].nil? && (!@current_pipeline.last_flush_timestamp_map.has_key?(@task_id) || Time.now > @current_pipeline.last_flush_timestamp_map[@task_id] + @inactivity_timeout / 2 || options[:final])
      events_to_flush = remove_expired_maps()

      # at Logstash shutdown, if push_previous_map_as_event is enabled, it's important to force flush (particularly for jdbc input plugin)
      @current_pipeline.mutex.synchronize do
        if options[:final] && @push_previous_map_as_event && !@current_pipeline.aggregate_maps[@task_id].empty?
          events_to_flush << extract_previous_map_as_event()
        end
      end

      # tag flushed events, indicating "final flush" special event
      if options[:final]
        events_to_flush.each { |event_to_flush| event_to_flush.tag("_aggregatefinalflush") }
      end

      # update last flush timestamp
      @current_pipeline.last_flush_timestamp_map[@task_id] = Time.now

      # return events to flush into Logstash pipeline
      return events_to_flush
    else
      return []
    end

  end


  # Remove the expired Aggregate maps from @current_pipeline.aggregate_maps if they are older than timeout or if no new event has been received since inactivity_timeout.
  # If @push_previous_map_as_event option is set, or @push_map_as_event_on_timeout is set, expired maps are returned as new events to be flushed to Logstash pipeline.
  def remove_expired_maps()
    events_to_flush = []
    min_timestamp = Time.now - @timeout
    min_inactivity_timestamp = Time.now - @inactivity_timeout

    @current_pipeline.mutex.synchronize do

      @logger.debug("Aggregate remove_expired_maps call with '#{@task_id}' pattern and #{@current_pipeline.aggregate_maps[@task_id].length} maps")

      @current_pipeline.aggregate_maps[@task_id].delete_if do |key, element|
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
  
  # return current pipeline id
  def pipeline_id()
    if @execution_context
      return @execution_context.pipeline_id
    else
      return pipeline_id = "main"
    end
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

# shared aggregate attributes for each pipeline
class LogStash::Filters::Aggregate::Pipeline
  
  attr_accessor :aggregate_maps, :mutex, :default_timeout, :flush_instance_map, :last_flush_timestamp_map, :aggregate_maps_path_set, :pipeline_close_instance

  def initialize()
    # Stores all aggregate maps, per task_id pattern, then per task_id value
    @aggregate_maps = {}
  
    # Mutex used to synchronize access to 'aggregate_maps'
    @mutex = Mutex.new
  
    # Default timeout for task_id patterns where timeout is not defined in Logstash filter configuration
    @default_timeout = nil
  
    # For each "task_id" pattern, defines which Aggregate instance will process flush() call, processing expired Aggregate elements (older than timeout)
    # For each entry, key is "task_id pattern" and value is "aggregate instance"
    @flush_instance_map = {}
  
    # last time where timeout management in flush() method was launched, per "task_id" pattern
    @last_flush_timestamp_map = {}
  
    # flag indicating if aggregate_maps_path option has been already set on one aggregate instance
    @aggregate_maps_path_set = false
  
    # defines which Aggregate instance will close Aggregate variables associated to current pipeline
    @pipeline_close_instance = nil
  end
end
