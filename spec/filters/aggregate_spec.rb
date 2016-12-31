# encoding: utf-8
require "logstash/devutils/rspec/spec_helper"
require "logstash/filters/aggregate"
require_relative "aggregate_spec_helper"

describe LogStash::Filters::Aggregate do

  before(:each) do
    reset_timeout_management()
    aggregate_maps.clear()
    @start_filter = setup_filter({ "map_action" => "create", "code" => "map['sql_duration'] = 0" })
    @update_filter = setup_filter({ "map_action" => "update", "code" => "map['sql_duration'] += event.get('duration')" })
    @end_filter = setup_filter({"timeout_task_id_field" => "my_id", "push_map_as_event_on_timeout" => true, "map_action" => "update", "code" => "event.set('sql_duration', map['sql_duration'])", "end_of_task" => true, "timeout" => 5, "timeout_code" => "event.set('test', 'testValue')", "timeout_tags" => ["tag1", "tag2"] })
  end

  context "Start event" do
    describe "and receiving an event without task_id" do
      it "does not record it" do
        @start_filter.filter(event())
        expect(aggregate_maps["%{taskid}"]).to be_empty
      end
    end
    describe "and receiving an event with task_id" do
      it "records it" do
        event = start_event("taskid" => "id123")
        @start_filter.filter(event)

        expect(aggregate_maps["%{taskid}"].size).to eq(1)
        expect(aggregate_maps["%{taskid}"]["id123"]).not_to be_nil
        expect(aggregate_maps["%{taskid}"]["id123"].creation_timestamp).to be >= event.timestamp.time
        expect(aggregate_maps["%{taskid}"]["id123"].map["sql_duration"]).to eq(0)
      end
    end

    describe "and receiving two 'start events' for the same task_id" do
      it "keeps the first one and does nothing with the second one" do

        first_start_event = start_event("taskid" => "id124")
        @start_filter.filter(first_start_event)
        
        first_update_event = update_event("taskid" => "id124", "duration" => 2)
        @update_filter.filter(first_update_event)
        
        sleep(1)
        second_start_event = start_event("taskid" => "id124")
        @start_filter.filter(second_start_event)

        expect(aggregate_maps["%{taskid}"].size).to eq(1)
        expect(aggregate_maps["%{taskid}"]["id124"].creation_timestamp).to be < second_start_event.timestamp.time
        expect(aggregate_maps["%{taskid}"]["id124"].map["sql_duration"]).to eq(first_update_event.get("duration"))
      end
    end
  end

  context "End event" do
    describe "receiving an event without a previous 'start event'" do
      describe "but without a previous 'start event'" do
        it "does nothing with the event" do
          end_event = end_event("taskid" => "id124")
          @end_filter.filter(end_event)

          expect(aggregate_maps["%{taskid}"]).to be_empty
          expect(end_event.get("sql_duration")).to be_nil
        end
      end
    end
  end

  context "Start/end events interaction" do
    describe "receiving a 'start event'" do
      before(:each) do
        @task_id_value = "id_123"
        @start_event = start_event({"taskid" => @task_id_value})
        @start_filter.filter(@start_event)
        expect(aggregate_maps["%{taskid}"].size).to eq(1)
      end

      describe "and receiving an end event" do
        describe "and without an id" do
          it "does nothing" do
            end_event = end_event()
            @end_filter.filter(end_event)
            expect(aggregate_maps["%{taskid}"].size).to eq(1)
            expect(end_event.get("sql_duration")).to be_nil
          end
        end

        describe "and an id different from the one of the 'start event'" do
          it "does nothing" do
            different_id_value = @task_id_value + "_different"
            @end_filter.filter(end_event("taskid" => different_id_value))

            expect(aggregate_maps["%{taskid}"].size).to eq(1)
            expect(aggregate_maps["%{taskid}"][@task_id_value]).not_to be_nil
          end
        end

        describe "and the same id of the 'start event'" do
          it "add 'sql_duration' field to the end event and deletes the aggregate map associated to taskid" do
            expect(aggregate_maps["%{taskid}"].size).to eq(1)
            expect(aggregate_maps["%{taskid}"][@task_id_value].map["sql_duration"]).to eq(0)

            @update_filter.filter(update_event("taskid" => @task_id_value, "duration" => 2))
            expect(aggregate_maps["%{taskid}"][@task_id_value].map["sql_duration"]).to eq(2)

            end_event = end_event("taskid" => @task_id_value)
            @end_filter.filter(end_event)

            expect(aggregate_maps["%{taskid}"]).to be_empty
            expect(end_event.get("sql_duration")).to eq(2)
          end

        end
      end
    end
  end

  context "Event with integer task id" do
    it "works as well as with a string task id" do
      start_event = start_event("taskid" => 124)
      @start_filter.filter(start_event)
      expect(aggregate_maps["%{taskid}"].size).to eq(1)
    end
  end

  context "Event which causes an exception when code call" do
    it "intercepts exception, logs the error and tags the event with '_aggregateexception'" do
      @start_filter = setup_filter({ "code" => "fail 'Test'" })
      start_event = start_event("taskid" => "id124")
      @start_filter.filter(start_event)

      expect(start_event.get("tags")).to eq(["_aggregateexception"])
    end
  end

  context "flush call" do
    before(:each) do
      @end_filter.timeout = 1
      expect(@end_filter.timeout).to eq(1)
      @task_id_value = "id_123"
      @start_event = start_event({"taskid" => @task_id_value})
      @start_filter.filter(@start_event)
      expect(aggregate_maps["%{taskid}"].size).to eq(1)
    end

    describe "no timeout defined in none filter" do
      it "defines a default timeout on a default filter" do
        reset_timeout_management()
        expect(taskid_eviction_instance).to be_nil
        @end_filter.flush()
        expect(taskid_eviction_instance).to eq(@end_filter)
        expect(@end_filter.timeout).to eq(LogStash::Filters::Aggregate::DEFAULT_TIMEOUT)
      end
    end

    describe "timeout is defined on another filter" do
      it "taskid eviction_instance is not updated" do
        expect(taskid_eviction_instance).not_to be_nil
        @start_filter.flush()
        expect(taskid_eviction_instance).not_to eq(@start_filter)
        expect(taskid_eviction_instance).to eq(@end_filter)
      end
    end

    describe "no timeout defined on the filter" do
      it "event is not removed" do
        sleep(2)
        @start_filter.flush()
        expect(aggregate_maps["%{taskid}"].size).to eq(1)
      end
    end

    describe "timeout defined on the filter" do
      it "event is not removed if not expired" do
        entries = @end_filter.flush()
        expect(aggregate_maps["%{taskid}"].size).to eq(1)
        expect(entries).to be_empty
      end
      it "removes event if expired and creates a new timeout event" do
        sleep(2)
        entries = @end_filter.flush()
        expect(aggregate_maps["%{taskid}"]).to be_empty
        expect(entries.size).to eq(1)
        expect(entries[0].get("my_id")).to eq("id_123") # task id 
        expect(entries[0].get("sql_duration")).to eq(0) # Aggregation map
        expect(entries[0].get("test")).to eq("testValue") # Timeout code
        expect(entries[0].get("tags")).to eq(["tag1", "tag2"]) # Timeout tags
      end
    end

    describe "timeout defined on another filter with another task_id pattern" do
      it "does not remove event" do
        another_filter = setup_filter({ "task_id" => "%{another_taskid}", "code" => "", "timeout" => 1 })
        sleep(2)
        entries = another_filter.flush()
        expect(aggregate_maps["%{taskid}"].size).to eq(1)
        expect(entries).to be_empty
      end
    end
  end

  context "aggregate_maps_path option is defined, " do
    describe "close event append then register event append, " do
      it "stores aggregate maps to configured file and then loads aggregate maps from file" do
        store_file = "aggregate_maps"
        expect(File.exist?(store_file)).to be false
          
        store_filter = setup_filter({ "code" => "map['sql_duration'] = 0", "aggregate_maps_path" => store_file })
        expect(aggregate_maps["%{taskid}"]).to be_empty

        start_event = start_event("taskid" => 124)
        filter = store_filter.filter(start_event)
        expect(aggregate_maps["%{taskid}"].size).to eq(1)
        
        store_filter.close()
        expect(File.exist?(store_file)).to be true
        expect(aggregate_maps).to be_empty

        store_filter = setup_filter({ "code" => "map['sql_duration'] = 0", "aggregate_maps_path" => store_file })
        expect(File.exist?(store_file)).to be false
        expect(aggregate_maps["%{taskid}"].size).to eq(1)
      end
    end

    describe "when aggregate_maps_path option is defined in 2 instances, " do
      it "raises Logstash::ConfigurationError" do
        expect {
          setup_filter({ "code" => "", "aggregate_maps_path" => "aggregate_maps1" })
          setup_filter({ "code" => "", "aggregate_maps_path" => "aggregate_maps2" })
        }.to raise_error(LogStash::ConfigurationError)
      end
    end
  end
  
  context "push_previous_map_as_event option is defined, " do 
    describe "when push_previous_map_as_event option is activated on another filter with same task_id pattern" do
      it "should throw a LogStash::ConfigurationError" do
        expect {
          setup_filter({"code" => "map['taskid'] = event.get('taskid')", "push_previous_map_as_event" => true})
        }.to raise_error(LogStash::ConfigurationError)
      end
    end
    
    describe "when a new task id is detected, " do
      it "should push previous map as new event" do
        push_filter = setup_filter({ "task_id" => "%{ppm_id}", "code" => "map['ppm_id'] = event.get('ppm_id')", "push_previous_map_as_event" => true, "timeout" => 5, "timeout_task_id_field" => "timeout_task_id_field" })
        push_filter.filter(event({"ppm_id" => "1"})) { |yield_event| fail "task 1 shouldn't have yield event" }
        push_filter.filter(event({"ppm_id" => "2"})) { |yield_event| expect(yield_event.get("ppm_id")).to eq("1") ; expect(yield_event.get("timeout_task_id_field")).to eq("1") }
        expect(aggregate_maps["%{ppm_id}"].size).to eq(1)
      end
    end

    describe "when timeout happens, " do
      it "flush method should return last map as new event" do
        push_filter = setup_filter({ "task_id" => "%{ppm_id}", "code" => "map['ppm_id'] = event.get('ppm_id')", "push_previous_map_as_event" => true, "timeout" => 1, "timeout_code" => "event.set('test', 'testValue')" })
        push_filter.filter(event({"ppm_id" => "1"}))
        sleep(2)
        events_to_flush = push_filter.flush()
        expect(events_to_flush).not_to be_nil
        expect(events_to_flush.size).to eq(1)
        expect(events_to_flush[0].get("ppm_id")).to eq("1")
        expect(events_to_flush[0].get('test')).to eq("testValue")
        expect(aggregate_maps["%{ppm_id}"].size).to eq(0)
      end
    end
  end
  

end
