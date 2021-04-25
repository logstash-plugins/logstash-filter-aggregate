# encoding: utf-8
require "logstash/filters/aggregate"

def event(data = {})
	LogStash::Event.new(data)
end

def timestamp(iso8601)
  LogStash::Timestamp.new(iso8601)
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

def pipelines()
  LogStash::Filters::Aggregate.class_variable_get(:@@pipelines)
end

def current_pipeline()
  pipelines()['main']
end

def aggregate_maps()
  current_pipeline().aggregate_maps
end

def taskid_eviction_instance()
  current_pipeline().flush_instance_map["%{taskid}"]
end

def pipeline_close_instance()
  current_pipeline().pipeline_close_instance
end

def aggregate_maps_path_set()
  current_pipeline().aggregate_maps_path_set
end

def reset_timeout_management()
  current_pipeline().flush_instance_map.clear()
  current_pipeline().last_flush_timestamp_map.clear()
end

def reset_pipeline_variables()
  pipelines().clear()
#  reset_timeout_management()
#  aggregate_maps().clear()
#  current_pipeline().pipeline_close_instance = nil
#  current_pipeline().aggregate_maps_path_set = false
end
