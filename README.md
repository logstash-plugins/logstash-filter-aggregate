# Logstash Filter Aggregate Documentation

[![Travis Build Status](https://travis-ci.org/logstash-plugins/logstash-filter-aggregate.svg)](https://travis-ci.org/logstash-plugins/logstash-filter-aggregate)

The aim of this filter is to aggregate information available among several events (typically log lines) belonging to a same task, and finally push aggregated information into final task event.

You should be very careful to set logstash filter workers to 1 (`-w 1` flag) for this filter to work 
correctly otherwise documents
may be processed out of sequence and unexpected results will occur.


## Customised version

I have forked this repository because we had multiple requirements that this plugin almost fulfilled. So I decided to build a version on top of the original with the following features: 

* Expired aggregations create new events 
* Ability to timeout based on a timestamp field. This is because if you use a file input, and you reparse old input data, the timeout does not work as expected.
For example, if one has data from 1 year ago, and wants to timeout events that happened 10 minutes apart, the file input will parse too quickly to react to that. I added functionality to track the timestamps based on a field
* Ability to track different timstamps for different fields.
Again, if one parses a lot of files, there is no guaranteed order of files. So the timestamps tracked need to be mapped to a property that groups the correct values together. For me, this is the file path. So I can parse multiple files and expire events on internal timestamps of the respective files. Otherwise, parsing a file from 1 year agao, and then a file from 1 month ago, will create a confusing timeout behaviour.
* Adding additional timeout on each event
If one enables timeout tracking and reparses a lot of data, this data needs to be checked after each event (because 2 events can come in 1ms apart, but advance the timestamp field used by several minutes/hours etc)

### New configration options

* **Note: If non of the configurations are set, the filter will behave as the original one. **

* **timeout_code**

This is the code to be executed when an aggregation times out

* **timeout_id**

This is simply the mapping that will be applied to the task-id values of the original config. So once a timeout occurs, the key of that aggregation will be added with the timeout_id as key. For example, if a task has an id saying task_id => "test1", the expired event will have a field event['timeout_id'] = map['task_id']

* **timestamp_field**

This field tells the filter where to find the timestamp to use for tracking. This timestamp will pe parsed, so it needs to be a valid timestamp. you can test that by going into a ruby interactive shell and doing: 

Time.parse("my-timestamp-representatin")

for example:

Time.parse("2016-06-11 14:07:46 +0100");

* **timestamp_key**
This is the tracking key that indentifies which timestamp to use for tracking. For example, if you are parsing X files, you could set that to "file_path". This way, there will be a mapping of 

[ "my-path-to-file" => "2016-06-11 14:07:46 +0100"]

That way each event will have a dedicated correlation timestamp and it does not matter if files come in out of order

* **track_times**

This enables tracking of times based on timestamp_key and timestamp_field. It can be true or false

* **flush_on_all_events**

This enables flushing on all events. It can be true or false. If true, every event will first evict aggregations before processing. All evicted aggregations will create new events using the timeout_code. 

### What does it do

If tracking times is enabled, the timeout behaviour changes. 

All events will populate a second map with a timestamp, looking like that:

```
map[event['timestamp_key']] = Time.parse(event['timestamp_field'])
```

the aggregation is then created as usual with one addition: It adds a **last_modified** timestamp. This timestamp is the base for eviction. 

Eviction then follows these rules: 

 * The entry in the map is checked against the last_modified timestamp. If  event_timestamp - last_modified > timeout, the entry is evicted
 * The timestamp entries created by the timestamp_field have a last_modified timestamp associated with them. If the last_modified of the eviction has been longer than the timeout defined, the entry is evicted. 

 In both cases events are created using the timeout_code. 

### Example configuration: 
```
filter {

    # Uses the json filter to parse the file input and adds the path field to it
    json {
        source => "message"
        add_field => { "file_path" => "%{path}"}
    }

    if [eventType] == "MY_TYPE" {
        aggregate {
          task_id => "%{task_id}"
          code => " map['count'] ||= 0; 
                    map['count'] += 1; 
                  "
          flush_on_all_events => true # enables flushing for all events


          timeout_code => "event['count'] = map['count']; event['type'] = 'TIMEOUT_EVENT'; event['path'] = map['path']"
          timeout_id => "task_id" # will map task_id in the generated event to the key "task_id"
          timeout => 900 
          periodic_flush => true 
          timestamp_field => "timestamp" # Tells the filter to use the event's timestamp that is in the field "timestamp"
          timestamp_key => "path" # Tells the filter to track timestamps based on the common field "field" which groups events from one file
          track_times => true # Enables the above configuration
        }
    }
    
}
```


## Example #1

* with these given logs : 
```
     INFO - 12345 - TASK_START - start
     INFO - 12345 - SQL - sqlQuery1 - 12
     INFO - 12345 - SQL - sqlQuery2 - 34
     INFO - 12345 - TASK_END - end
```

* you can aggregate "sql duration" for the whole task with this configuration : 
``` ruby
     filter {
         grok {
             match => [ "message", "%{LOGLEVEL:loglevel} - %{NOTSPACE:taskid} - %{NOTSPACE:logger} - %{WORD:label}( - %{INT:duration:int})?" ]
         }
     
         if [logger] == "TASK_START" {
             aggregate {
                 task_id => "%{taskid}"
                 code => "map['sql_duration'] = 0"
                 map_action => "create"
             }
         }
     
         if [logger] == "SQL" {
             aggregate {
                 task_id => "%{taskid}"
                 code => "map['sql_duration'] += event['duration']"
                 map_action => "update"
             }
         }
     
         if [logger] == "TASK_END" {
             aggregate {
                 task_id => "%{taskid}"
                 code => "event['sql_duration'] = map['sql_duration']"
                 map_action => "update"
                 end_of_task => true
                 timeout => 120
             }
         }
     }
```

* the final event then looks like :
``` ruby
{
         "message" => "INFO - 12345 - TASK_END - end",
    "sql_duration" => 46
}
```

the field `sql_duration` is added and contains the sum of all sql queries durations.

## Example #2

* If you have the same logs than example #1, but without a start log : 
```
     INFO - 12345 - SQL - sqlQuery1 - 12
     INFO - 12345 - SQL - sqlQuery2 - 34
     INFO - 12345 - TASK_END - end
```

* you can also aggregate "sql duration" with a slightly different configuration : 
``` ruby
     filter {
         grok {
             match => [ "message", "%{LOGLEVEL:loglevel} - %{NOTSPACE:taskid} - %{NOTSPACE:logger} - %{WORD:label}( - %{INT:duration:int})?" ]
         }
     
         if [logger] == "SQL" {
             aggregate {
                 task_id => "%{taskid}"
                 code => "map['sql_duration'] ||= 0 ; map['sql_duration'] += event['duration']"
             }
         }
     
         if [logger] == "TASK_END" {
             aggregate {
                 task_id => "%{taskid}"
                 code => "event['sql_duration'] = map['sql_duration']"
                 end_of_task => true
                 timeout => 120
             }
         }
     }
```

* the final event is exactly the same than example #1
* the key point is the "||=" ruby operator.  
it allows to initialize 'sql_duration' map entry to 0 only if this map entry is not already initialized


## How it works
- the filter needs a "task_id" to correlate events (log lines) of a same task
- at the task beggining, filter creates a map, attached to task_id
- for each event, you can execute code using 'event' and 'map' (for instance, copy an event field to map)
- in the final event, you can execute a last code (for instance, add map data to final event)
- after the final event, the map attached to task is deleted
- in one filter configuration, it is recommanded to define a timeout option to protect the filter against unterminated tasks. It tells the filter to delete expired maps
- if no timeout is defined, by default, all maps older than 1800 seconds are automatically deleted
- finally, if `code` execution raises an exception, the error is logged and event is tagged '_aggregateexception'

## Use Cases
- extract some cool metrics from task logs and push them into task final log event (like in example #1 and #2)
- extract error information in any task log line, and push it in final task event (to get a final document with all error information if any)
- extract all back-end calls as a list, and push this list in final task event (to get a task profile)
- extract all http headers logged in several lines to push this list in final task event (complete http request info)
- for every back-end call, collect call details available on several lines, analyse it and finally tag final back-end call log line (error, timeout, business-warning, ...)
- Finally, task id can be any correlation id matching your need : it can be a session id, a file path, ...

## Aggregate Plugin Options
- **task_id :**  
The expression defining task ID to correlate logs.  
This value must uniquely identify the task in the system.  
This option is required.  
Example value : `"%{application}%{my_task_id}"`  

- **code:**  
The code to execute to update map, using current event.  
Or on the contrary, the code to execute to update event, using current map.  
You will have a 'map' variable and an 'event' variable available (that is the event itself).  
This option is required.  
Example value : `"map['sql_duration'] += event['duration']"`  

- **map_action:**  
Tell the filter what to do with aggregate map (default :  "create_or_update").  
`create`: create the map, and execute the code only if map wasn't created before  
`update`: doesn't create the map, and execute the code only if map was created before  
`create_or_update`: create the map if it wasn't created before, execute the code in all cases  
Default value: `create_or_update`  

- **end_of_task:**  
Tell the filter that task is ended, and therefore, to delete map after code execution.  
Default value: `false`  

- **timeout:**  
The amount of seconds after a task "end event" can be considered lost.  
When timeout occurs for a task, The task "map" is evicted.  
If no timeout is defined, default timeout will be applied : 1800 seconds.  

- **aggregate_maps_path:**  
The path to file where aggregate maps are stored when logstash stops and are loaded from when logstash starts.  
If not defined, aggregate maps will not be stored at logstash stop and will be lost.   
Must be defined in only one aggregate filter (as aggregate maps are global).  
Example value : `"/path/to/.aggregate_maps"`


## Changelog

Read [CHANGELOG.md](CHANGELOG.md).


## Need Help?

Need help? Try #logstash on freenode IRC or the https://discuss.elastic.co/c/logstash discussion forum.


## Want to contribute?

Read [BUILD.md](BUILD.md).
