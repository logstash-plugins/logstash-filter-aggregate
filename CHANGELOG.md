## 2.3.1
 - new feature: Add new option "timeout_tags" so that you can add tags to generated timeout events
 
## 2.3.0
 - new feature: Add new option "push_map_as_event_on_timeout" so that when a task timeout happens the aggregation map can be yielded as a new event
 - new feature: Add new option "timeout_code" which takes the timeout event populated with the aggregation map and executes code on it. This works for "push_map_as_event_on_timeout" as well as "push_previous_map_as_event"
 - new feature: Add new option "timeout_task_id_field" which is used to map the task_id on timeout events.

## 2.2.0
 - new feature: add new option "push_previous_map_as_event" so that each time aggregate plugin detects a new task id, it pushes previous aggregate map as a new logstash event

## 2.1.2
 - bugfix: clarify default timeout behaviour : by default, timeout is 1800s 

## 2.1.1
 - bugfix: when "aggregate_maps_path" option is defined in more than one aggregate filter, raise a Logstash::ConfigurationError 
 - bugfix: add support for logstash hot reload feature 

## 2.1.0
 - new feature: add new option "aggregate_maps_path" so that aggregate maps can be stored at logstash shutdown and reloaded at logstash startup

## 2.0.5
 - internal,deps: Depend on logstash-core-plugin-api instead of logstash-core, removing the need to mass update plugins on major releases of logstash

## 2.0.4
 - internal,deps: New dependency requirements for logstash-core for the 5.0 release

## 2.0.3
 - bugfix: fix issue #10 : numeric task_id is now well processed

## 2.0.2
 - bugfix: fix issue #5 : when code call raises an exception, the error is logged and the event is tagged '_aggregateexception'. It avoids logstash crash.

## 2.0.0
 - internal: Plugins were updated to follow the new shutdown semantic, this mainly allows Logstash to instruct input plugins to terminate gracefully, 
   instead of using Thread.raise on the plugins' threads. Ref: https://github.com/elastic/logstash/pull/3895
 - internal,deps: Dependency on logstash-core update to 2.0

## 0.1.3
 - breaking: remove "milestone" method call which is deprecated in logstash 1.5, break compatibility with logstash 1.4
 - internal,test: enhanced tests using 'expect' command
 - docs: add a second example in documentation

## 0.1.2
 - compatible with logstash 1.4
 - first version available on github
