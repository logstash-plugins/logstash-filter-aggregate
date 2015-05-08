# Logstash Filter Aggregate Documentation

The aim of this filter is to aggregate informations available among several events (typically log lines) belonging to a same task, and finally push aggregated information into final task event.
 
## Example

* with this given data : 
```
     INFO - 12345 - TASK_START - start message
     INFO - 12345 - DAO - MyDao.findById - 12
     INFO - 12345 - DAO - MyDao.findAll - 34
     INFO - 12345 - TASK_END - end message
```

* you can aggregate "dao duration" with this configuration : 
``` ruby
     filter {
         grok {
             match => [ "message", "%{LOGLEVEL:loglevel} - %{NOTSPACE:requestid} - %{NOTSPACE:logger} - %{GREEDYDATA:msg}" ]
         }
     
         if [logger] == "TASK_START" {
             aggregate {
                 task_id => "%{requestid}"
                 code => "map['dao_duration'] = 0"
                 map_action => "create"
             }
         }
     
         if [logger] == "DAO" {
             grok {
                 match => [ "msg", "%{JAVACLASS:dao_call} - %{INT:duration:int}" ]
             }
             aggregate {
                 task_id => "%{requestid}"
                 code => "map['dao_duration'] += event['duration']"
                 map_action => "update"
             }
         }
     
         if [logger] == "TASK_END" {
             aggregate {
                 task_id => "%{requestid}"
                 code => "event.to_hash.merge!(map)"
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
         "message" => "INFO - 12345 - TASK_END - end message",
    "dao_duration" => 46
}
```

## How it works
- the filter needs a "task_id" to correlate events (log lines) of a same task
- at the task beggining, filter creates a map, attached to task_id
- for each event, you can execute code using 'event' and 'map' (for instance, copy an event field to map)
- in the final event, you can execute a last code (for instance, add map data to final event)
- after the final event, the map attached to task is deleted
- in one filter configuration, it is recommanded to define a timeout option to protect the filter against unterminated tasks. It tells the filter to delete expired maps
- if no timeout is defined, by default, all maps older than 1800 seconds are automatically deleted

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
Example value : `"map['dao_duration'] += event['duration']"`  

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
The task "map" is then evicted.  
The default value is 0, which means no timeout so no auto eviction.  
