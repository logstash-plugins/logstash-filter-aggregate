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

def aggregate_maps()
	LogStash::Filters::Aggregate.aggregate_maps
end

def filter(event)
	@start_filter.filter(event)
	@update_filter.filter(event)
	@end_filter.filter(event)
end

