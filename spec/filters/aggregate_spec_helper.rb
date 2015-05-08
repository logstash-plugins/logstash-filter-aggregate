# encoding: utf-8
require "logstash/filters/aggregate"

def event(data = {})
	data["message"] ||= "Log message"
	data["@timestamp"] ||= Time.now
	LogStash::Event.new(data)
end

def start_event(data = {})
	data["logger"] = "TASK_START"
	event(data)
end

def update_event(data = {})
	data["logger"] = "DAO"
	event(data)
end

def end_event(data = {})
	data["logger"] = "TASK_END"
	event(data)
end

def setup_filter(config = {})
	config["task_id"] ||= "%{requestid}"
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

def eviction_instance()
	LogStash::Filters::Aggregate.class_variable_get(:@@eviction_instance)
end

def set_eviction_instance(new_value)
	LogStash::Filters::Aggregate.class_variable_set(:@@eviction_instance, new_value)
end

