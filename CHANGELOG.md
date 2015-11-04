# v 0.1.5
- fix issue #10 : numeric task_id is now well processed

# v 0.1.4
- fix issue #5 : when code call raises an exception, the error is logged and the event is tagged '_aggregateexception'. It avoids logstash crash.

# v 0.1.3
- break compatibility with logstash 1.4
- remove "milestone" method call which is deprecated in logstash 1.5
- enhanced tests using 'expect' command
- add a second example in documentation

# v 0.1.2
- compatible with logstash 1.4
- first version available on github
