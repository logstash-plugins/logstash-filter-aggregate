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
             match => [ "message", "%{SPACE}%{LOGLEVEL:loglevel} - %{NOTSPACE:requestid} - %{NOTSPACE:logger} - %{GREEDYDATA:msg}(\n%{GREEDYDATA})?" ]
         }
     
         if [logger] == "TASK_START" {
             aggregate {
                 task_id => "%{requestid}"
                 code => "map['dao.duration'] = 0"
                 map_action => "create"
             }
         }
     
         if [logger] == "DAO" {
             grok {
                 match => [ "msg", "%{JAVACLASS:dao_call} - %{INT:duration:int}" ]
             }
             aggregate {
                 task_id => "%{requestid}"
                 code => "map['dao.duration'] += event['duration']"
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
    "dao.duration" => 46
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
Example value : `"map['dao.duration'] += event['duration']"`  

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


# Logstash Plugin

This is a plugin for [Logstash](https://github.com/elasticsearch/logstash).

It is fully free and fully open source. The license is Apache 2.0, meaning you are pretty much free to use it however you want in whatever way.

## Documentation

Logstash provides infrastructure to automatically generate documentation for this plugin. We use the asciidoc format to write documentation so any comments in the source code will be first converted into asciidoc and then into html. All plugin documentation are placed under one [central location](http://www.elasticsearch.org/guide/en/logstash/current/).

- For formatting code or config example, you can use the asciidoc `[source,ruby]` directive
- For more asciidoc formatting tips, see the excellent reference here https://github.com/elasticsearch/docs#asciidoc-guide

## Need Help?

Need help? Try #logstash on freenode IRC or the logstash-users@googlegroups.com mailing list.

## Developing

### 1. Plugin Developement and Testing

#### Code
- To get started, you'll need JRuby with the Bundler gem installed.

- Create a new plugin or clone and existing from the GitHub [logstash-plugins](https://github.com/logstash-plugins) organization. We also provide [example plugins](https://github.com/logstash-plugins?query=example).

- Install dependencies
```sh
bundle install
```

#### Test

- Update your dependencies

```sh
bundle install
```

- Run tests

```sh
bundle exec rspec
```

### 2. Running your unpublished Plugin in Logstash

#### 2.1 Run in a local Logstash clone

- Edit Logstash `Gemfile` and add the local plugin path, for example:
```ruby
gem "logstash-filter-awesome", :path => "/your/local/logstash-filter-awesome"
```
- Install plugin
```sh
bin/plugin install --no-verify
```
- Run Logstash with your plugin
```sh
bin/logstash -e 'filter {awesome {}}'
```
At this point any modifications to the plugin code will be applied to this local Logstash setup. After modifying the plugin, simply rerun Logstash.

#### 2.2 Run in an installed Logstash

You can use the same **2.1** method to run your plugin in an installed Logstash by editing its `Gemfile` and pointing the `:path` to your local plugin development directory or you can build the gem and install it using:

- Build your plugin gem
```sh
gem build logstash-filter-awesome.gemspec
```
- Install the plugin from the Logstash home
```sh
bin/plugin install /your/local/plugin/logstash-filter-awesome.gem
```
- Start Logstash and proceed to test the plugin

## Contributing

All contributions are welcome: ideas, patches, documentation, bug reports, complaints, and even something you drew up on a napkin.

Programming is not a required skill. Whatever you've seen about open source and maintainers or community members  saying "send patches or die" - you will not see that here.

It is more important to the community that you are able to contribute.

For more information about contributing, see the [CONTRIBUTING](https://github.com/elasticsearch/logstash/blob/master/CONTRIBUTING.md) file.