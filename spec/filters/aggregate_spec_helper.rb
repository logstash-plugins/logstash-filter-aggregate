# encoding: utf-8
require "logstash/filters/aggregate"

def event(data = {})
	LogStash::Event.new(data)
end

def start_event(data = {})
	data["logger"] = "TASK_START"
	event(data)
end

def update_event(data = {})
	data["logger"] = "SQL"
	event(data)
end

def end_event(data = {})
	data["logger"] = "TASK_END"
	event(data)
end

def setup_filter(config = {})
	config["task_id"] ||= "%{taskid}"
	filter = LogStash::Filters::Aggregate.new(config)
	filter.register()
	return filter
end

def filter(event)
	@start_filter.filter(event)
	@update_filter.filter(event)
	@end_filter.filter(event)
end

def aggregate_maps()
	LogStash::Filters::Aggregate.class_variable_get(:@@aggregate_maps)
end

def taskid_eviction_instance()
	LogStash::Filters::Aggregate.class_variable_get(:@@eviction_instance_map)["%{taskid}"]
end

def static_close_instance()
  LogStash::Filters::Aggregate.class_variable_get(:@@static_close_instance)
end

def aggregate_maps_path_set()
  LogStash::Filters::Aggregate.class_variable_get(:@@aggregate_maps_path_set)
end

def reset_timeout_management()
	LogStash::Filters::Aggregate.class_variable_set(:@@default_timeout, nil)
  LogStash::Filters::Aggregate.class_variable_get(:@@eviction_instance_map).clear()
  LogStash::Filters::Aggregate.class_variable_get(:@@last_eviction_timestamp_map).clear()
end

def reset_static_variables()
  reset_timeout_management()
  aggregate_maps().clear()
  LogStash::Filters::Aggregate.class_variable_set(:@@static_close_instance, nil)
  LogStash::Filters::Aggregate.class_variable_set(:@@aggregate_maps_path_set, false)
end
