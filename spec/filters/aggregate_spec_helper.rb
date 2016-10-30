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

def reset_timeout_management()
	LogStash::Filters::Aggregate.class_variable_set(:@@default_timeout, nil)
  LogStash::Filters::Aggregate.class_variable_get(:@@eviction_instance_map).clear()
end
