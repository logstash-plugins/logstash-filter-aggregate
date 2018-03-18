Gem::Specification.new do |s|
  s.name = 'logstash-filter-aggregate'
  s.version         = '2.8.0'
  s.licenses = ['Apache License (2.0)']
  s.summary = "Aggregates information from several events originating with a single task"
  s.description = 'This gem is a Logstash plugin required to be installed on top of the Logstash core pipeline using $LS_HOME/bin/logstash-plugin install gemname. This gem is not a stand-alone program'
  s.authors = ['Elastic', 'Fabien Baligand']
  s.email = 'info@elastic.co'
  s.homepage = 'https://github.com/logstash-plugins/logstash-filter-aggregate'
  s.require_paths = ['lib']

  # Files
  s.files = Dir["lib/**/*","spec/**/*","*.gemspec","*.md","CONTRIBUTORS","Gemfile","LICENSE","NOTICE.TXT", "vendor/jar-dependencies/**/*.jar", "vendor/jar-dependencies/**/*.rb", "VERSION", "docs/**/*"]

  # Tests
  s.test_files = s.files.grep(%r{^(test|spec|features)/})

  # Special flag to let us know this is actually a logstash plugin
  s.metadata = { 'logstash_plugin' => 'true', 'logstash_group' => 'filter' }

  # Gem dependencies
  s.add_runtime_dependency 'logstash-core-plugin-api', '>= 1.60', '<= 2.99'
  
  # Gem test dependencies
  s.add_development_dependency 'logstash-devutils'
end
