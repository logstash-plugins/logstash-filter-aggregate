# Logstash Filter Aggregate Documentation

[![Travis Build Status](https://travis-ci.org/logstash-plugins/logstash-filter-aggregate.svg)](https://travis-ci.org/logstash-plugins/logstash-filter-aggregate)

The aim of this filter is to aggregate information available among several events (typically log lines) belonging to a same task, and finally push aggregated information into final task event.

You should be very careful to set logstash filter workers to 1 (`-w 1` flag) for this filter to work correctly 
otherwise events may be processed out of sequence and unexpected results will occur.
 
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

## Example #3

Third use case: You have a start event, however no specific end event. 

A typical case is aggregating or tracking user behaviour. We can track a user by its ID through the events, however once the user stops interacting, the events stop coming in. There is no specific event indicating the end of the user's interaction.

In this case, we can enable the option 'push_map_as_event_on_timeout' to enable pushing the aggregation map as a new event. 
In addition, we can enable 'timeout_code' to execute code on the populated timeout event.
We can also add 'timeout_task_id_field' so we can correlate the task_id, which in this case would be the user's ID. 

```
    INFO - 12345 - Clicked One
    INFO - 12345 - Clicked Two
    INFI - 12345 - Clicked Three
```

* You can aggregate the amount of clicks the user did like this:

``` ruby
    filter {
        grok {
                 match => [ "message", "%{LOGLEVEL:loglevel} - %{NOTSPACE:taskid} - %{GREEDYDATA:msgtext}" ]
        }

        aggregate {
            task_id => "%{taskid}"
            code => "map['clicks'] ||= 0; map['clicks'] += 1;"
            timeout_task_id_field => "userId"
            timeout => 600 # 10 minutes timeout
            timeout_code => "event['tags'] = '_aggregatetimeout'"
        }

    }
```

* After ten minutes, this will yield an event like:

``` json
    {
        "userId" : "12345",
        "clicks" : 3,
        "tags" : [
            "_aggregatetimeout"
        ]
    }
```


## Example #4

Fourth use case : you have no specific start event and no specific end event.  
A typical case is aggregating results from jdbc input plugin.  
* Given that you have this SQL query : `SELECT country_name, town_name FROM town`  
* Using jdbc input plugin, you get these 3 events from :
``` json
  { "country_name": "France", "town_name": "Paris" }
  { "country_name": "France", "town_name": "Marseille" }
  { "country_name": "USA", "town_name": "New-York" }
```
* And you would like these 2 result events to push them into elasticsearch :
``` json
  { "country_name": "France", "town_name": [ "Paris", "Marseille" ] }
  { "country_name": "USA", "town_name": [ "New-York" ] }
```
* You can do that using `push_previous_map_as_event` aggregate plugin option :
``` ruby
     filter {
         aggregate {
             task_id => "%{country_name}"
             code => "
                map['tags'] ||= ['aggregated']
                map['town_name'] ||= []
                event.to_hash.each do |key,value|
                    map[key] = value unless map.has_key?(key)
                    map[key] << value if map[key].is_a?(Array)
                end
             "
             push_previous_map_as_event => true
             timeout => 5
         }

         if "aggregated" not in [tags] {
            drop {}
         }
     }
```
* The key point is that, each time aggregate plugin detects a new `country_name`, it pushes previous aggregate map as a new logstash event (with 'aggregated' tag), and then creates a new empty map for the next country
* When 5s timeout comes, the last aggregate map is pushed as a new event
* Finally, initial events (which are not aggregated) are dropped because useless

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
- extract error information in any task log line, and push it in final task event (to get a final event with all error information if any)
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

- **push_previous_map_as_event:**  
When this option is enabled, each time aggregate plugin detects a new task id, it pushes previous aggregate map as a new logstash event, 
and then creates a new empty map for the next task.  
_WARNING:_ this option works fine only if tasks come one after the other. It means : all task1 events, then all task2 events, etc...  
Default value: `false`  


## Changelog

Read [CHANGELOG.md](CHANGELOG.md).


## Need Help?

Need help? Try #logstash on freenode IRC or the https://discuss.elastic.co/c/logstash discussion forum.


## Want to contribute?

Read [BUILD.md](BUILD.md).
