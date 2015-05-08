# encoding: utf-8
require "logstash/devutils/rspec/spec_helper"
require "logstash/filters/aggregate"
require_relative "aggregate_spec_helper"

describe LogStash::Filters::Aggregate do

	before(:each) do
		LogStash::Filters::Aggregate.set_eviction_instance_nil()
		aggregate_maps.clear()
		@start_filter = setup_filter({ "map_action" => "create", "code" => "map['dao.duration'] = 0" })
		@update_filter = setup_filter({ "map_action" => "update", "code" => "map['dao.duration'] += event['duration']" })
		@end_filter = setup_filter({ "map_action" => "update", "code" => "event.to_hash.merge!(map)", "end_of_task" => true, "timeout" => 5 })
	end

	context "Start event" do
		describe "and receiving an event without task_id" do
			it "does not record it" do
				@start_filter.filter(event())
				expect(aggregate_maps).to be_empty
			end
		end
		describe "and receiving an event with task_id" do
			it "records it" do
				event = start_event("requestid" => "id123")
				@start_filter.filter(event)

				expect(aggregate_maps.size).to eq(1)
				expect(aggregate_maps["id123"]).not_to be_nil
				expect(aggregate_maps["id123"].creation_timestamp).to be >= event["@timestamp"]
				expect(aggregate_maps["id123"].map["dao.duration"]).to eq(0)
			end
		end

		describe "and receiving two 'start events' for the same task_id" do
			it "keeps the first one and does nothing with the second one" do

				first_start_event = start_event("requestid" => "id124")
				@start_filter.filter(first_start_event)
				
				first_update_event = update_event("requestid" => "id124", "duration" => 2)
				@update_filter.filter(first_update_event)
				
				sleep(1)
				second_start_event = start_event("requestid" => "id124")
				@start_filter.filter(second_start_event)

				expect(aggregate_maps.size).to eq(1)
				expect(aggregate_maps["id124"].creation_timestamp).to be < second_start_event["@timestamp"]
				expect(aggregate_maps["id124"].map["dao.duration"]).to eq(first_update_event["duration"])
			end
		end
	end

	context "End event" do
		describe "receiving an event without a previous 'start event'" do
			describe "but without a previous 'start event'" do
				it "does nothing with the event" do
					end_event = end_event("requestid" => "id124")
					@end_filter.filter(end_event)

					expect(aggregate_maps).to be_empty
					expect(end_event["dao.duration"]).to be_nil
				end
			end
		end
	end

	context "Start/end events interaction" do
		describe "receiving a 'start event'" do
			before(:each) do
				@task_id_value = "id_123"
				@start_event = start_event({"requestid" => @task_id_value})
				@start_filter.filter(@start_event)
				expect(aggregate_maps.size).to eq(1)
			end

			describe "and receiving an end event" do
				describe "and without an id" do
					it "does nothing" do
						end_event = end_event()
						@end_filter.filter(end_event)
						expect(aggregate_maps.size).to eq(1)
						expect(end_event["dao.duration"]).to be_nil
					end
				end

				describe "and an id different from the one of the 'start event'" do
					it "does nothing" do
						different_id_value = @task_id_value + "_different"
						@end_filter.filter(end_event("requestid" => different_id_value))

						expect(aggregate_maps.size).to eq(1)
						expect(aggregate_maps[@task_id_value]).not_to be_nil
					end
				end

				describe "and the same id of the 'start event'" do
					it "add 'dao.duration' field to the end event and deletes the recorded 'start event'" do
						expect(aggregate_maps.size).to eq(1)

						@update_filter.filter(update_event("requestid" => @task_id_value, "duration" => 2))

						end_event = end_event("requestid" => @task_id_value)
						@end_filter.filter(end_event)

						expect(aggregate_maps).to be_empty
						expect(end_event["dao.duration"]).to eq(2)
					end

				end
			end
		end
	end

	context "flush call" do
		before(:each) do
			@end_filter.timeout = 1
			expect(@end_filter.timeout).to eq(1)
			@task_id_value = "id_123"
			@start_event = start_event({"requestid" => @task_id_value})
			@start_filter.filter(@start_event)
			expect(aggregate_maps.size).to eq(1)
		end

		describe "no timeout defined in none filter" do
			it "defines a default timeout on a default filter" do
				LogStash::Filters::Aggregate.set_eviction_instance_nil()
				expect(LogStash::Filters::Aggregate.eviction_instance).to be_nil
				@end_filter.flush()
				expect(LogStash::Filters::Aggregate.eviction_instance).to eq(@end_filter)
				expect(@end_filter.timeout).to eq(LogStash::Filters::Aggregate::DEFAULT_TIMEOUT)
			end
		end

		describe "timeout is defined on another filter" do
			it "eviction_instance is not updated" do
				expect(LogStash::Filters::Aggregate.eviction_instance).not_to be_nil
				@start_filter.flush()
				expect(LogStash::Filters::Aggregate.eviction_instance).not_to eq(@start_filter)
				expect(LogStash::Filters::Aggregate.eviction_instance).to eq(@end_filter)
			end
		end

		describe "no timeout defined on the filter" do
			it "event is not removed" do
				sleep(2)
				@start_filter.flush()
				expect(aggregate_maps.size).to eq(1)
			end
		end

		describe "timeout defined on the filter" do
			it "event is not removed if not expired" do
				@end_filter.flush()
				expect(aggregate_maps.size).to eq(1)
			end
			it "event is removed if expired" do
				sleep(2)
				@end_filter.flush()
				expect(aggregate_maps).to be_empty
			end
		end

	end

end
