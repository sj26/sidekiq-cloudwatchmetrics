require "spec_helper"

RSpec.describe Sidekiq::CloudWatchMetrics do
  describe ".enable!" do
    # Sidekiq.options is deprecated as of Sidekiq 6.5, and must be accessed
    # through Sidekiq[...] instead. In Sidekiq 7.0 we must use Sidekiq::Config.new
    let(:sidekiq_options) do
      return Sidekiq if Sidekiq.respond_to?(:[])
      return Sidekiq.options if Sidekiq.respond_to?(:options)

      Sidekiq::Config.new
    end

    # Sidekiq.options does a Sidekiq::DEFAULTS.dup which retains the same values, so
    # Sidekiq.options[:lifecycle_events] IS Sidekiq::DEFAULTS[:lifecycle_events] and
    # is mutable, so Sidekiq.options = nil will again Sidekiq::DEFAULTS.dup and get
    # the same Sidekiq::DEFAULTS[:lifecycle_events]. So we have to manually clear it.
    before { sidekiq_options[:lifecycle_events].each_value(&:clear) }

    context "in a sidekiq server" do
      before { allow(Sidekiq).to receive(:server?).and_return(true) }

      it "creates a metrics publisher and installs hooks" do
        publisher = instance_double(Sidekiq::CloudWatchMetrics::Publisher)
        expect(Sidekiq::CloudWatchMetrics::Publisher).to receive(:new).and_return(publisher)

        Sidekiq::CloudWatchMetrics.enable!

        # Look, this is hard.
        expect(sidekiq_options[:lifecycle_events][:startup]).not_to be_empty
        expect(sidekiq_options[:lifecycle_events][:quiet]).not_to be_empty
        expect(sidekiq_options[:lifecycle_events][:shutdown]).not_to be_empty
      end
    end

    context "in client mode" do
      before { allow(Sidekiq).to receive(:server?).and_return(false) }

      it "does nothing" do
        expect(Sidekiq::CloudWatchMetrics::Publisher).not_to receive(:new)

        Sidekiq::CloudWatchMetrics.enable!

        expect(sidekiq_options[:lifecycle_events][:startup]).to be_empty
        expect(sidekiq_options[:lifecycle_events][:quiet]).to be_empty
        expect(sidekiq_options[:lifecycle_events][:shutdown]).to be_empty
      end
    end
  end

  describe "Publisher" do
    let(:client) { instance_double(Aws::CloudWatch::Client) }
    before { allow(client).to receive(:put_metric_data) }

    subject(:publisher) { Sidekiq::CloudWatchMetrics::Publisher.new(client: client) }

    describe "#publish" do
      let(:stats) do
        instance_double(Sidekiq::Stats,
          processed: 123,
          failed: 456,
          enqueued: 6,
          scheduled_size: 1,
          retry_size: 2,
          dead_size: 3,
          queues: queues.transform_values(&:size),
          workers_size: 10,
          processes_size: 5,
          default_queue_latency: 1.23,
        )
      end
      let(:processes) do
        [
          Sidekiq::Process.new("busy" => 5, "concurrency" => 10, "hostname" => "foo"),
          Sidekiq::Process.new("busy" => 2, "concurrency" => 20, "hostname" => "bar"),
        ]
      end
      let(:queues) do
        {
          "foo" => double(size: 1, latency: 1.23),
          "bar" => double(size: 2, latency: 1.23),
        }
      end

      before do
        allow(Sidekiq::Stats).to receive(:new).and_return(stats)
        allow(Sidekiq::ProcessSet).to receive(:new).and_return(processes)
        allow(Sidekiq::Queue).to receive(:new) { |name| queues.fetch(name) }
      end

      it "publishes sidekiq metrics to cloudwatch" do
        Timecop.freeze(now = Time.now) do
          publisher.publish

          expect(client).to have_received(:put_metric_data).with(
            namespace: "Sidekiq",
            metric_data: contain_exactly(
              {
                metric_name: "ProcessedJobs",
                timestamp: now,
                value: 123,
                unit: "Count",
              },
              {
                metric_name: "FailedJobs",
                timestamp: now,
                value: 456,
                unit: "Count",
              },
              {
                metric_name: "EnqueuedJobs",
                timestamp: now,
                value: 6,
                unit: "Count",
              },
              {
                metric_name: "ScheduledJobs",
                timestamp: now,
                value: 1,
                unit: "Count",
              },
              {
                metric_name: "RetryJobs",
                timestamp: now,
                value: 2,
                unit: "Count",
              },
              {
                metric_name: "DeadJobs",
                timestamp: now,
                value: 3,
                unit: "Count",
              },
              {
                metric_name: "Workers",
                timestamp: now,
                value: 10,
                unit: "Count",
              },
              {
                metric_name: "Processes",
                timestamp: now,
                value: 5,
                unit: "Count",
              },
              {
                metric_name: "Capacity",
                timestamp: now,
                value: 30,
                unit: "Count",
              },
              {
                metric_name: "DefaultQueueLatency",
                timestamp: now,
                value: 1.23,
                unit: "Seconds",
              },
              {
                metric_name: "Utilization",
                timestamp: now,
                value: 30.0,
                unit: "Percent",
              },
              {
                metric_name: "Utilization",
                dimensions: [{name: "Hostname", value: "foo"}],
                timestamp: now,
                unit: "Percent",
                value: 50.0,
              },
              {
                metric_name: "Utilization",
                dimensions: [{name: "Hostname", value: "bar"}],
                timestamp: now,
                unit: "Percent",
                value: 10.0,
              },
              {
                metric_name: "QueueSize",
                dimensions: [{name: "QueueName", value: "foo"}],
                timestamp: now,
                value: 1,
                unit: "Count",
              },
              {
                metric_name: "QueueLatency",
                dimensions: [{name: "QueueName", value: "foo"}],
                timestamp: now,
                value: 1.23,
                unit: "Seconds",
              },
              {
                metric_name: "QueueSize",
                dimensions: [{name: "QueueName", value: "bar"}],
                timestamp: now,
                value: 2,
                unit: "Count",
              },
              {
                metric_name: "QueueLatency",
                dimensions: [{name: "QueueName", value: "bar"}],
                timestamp: now,
                value: 1.23,
                unit: "Seconds",
              },
            ),
          )
        end
      end

      context "with lots of queues" do
        let(:queues) { 10.times.each_with_object({}) { |i, hash| hash["queue#{i}"] = double(size: 1, latency: 1.23) } }

        it "publishes sidekiq metrics to cloudwatch in batches of 20" do
          Timecop.freeze(now = Time.now) do
            publisher.publish

            expect(client).to have_received(:put_metric_data) { |metrics|
              expect(metrics[:metric_data].size).to be <= 20
            }.at_least(:twice)
          end
        end
      end

      context "with process tags" do
        let(:processes) do
          [
            Sidekiq::Process.new("busy" => 5, "concurrency" => 10, "hostname" => "foo", "tag" => "default"),
            Sidekiq::Process.new("busy" => 2, "concurrency" => 20, "hostname" => "bar", "tag" => "shard-one"),
          ]
        end

        it "publishes metrics including tag as a dimension" do
          Timecop.freeze(now = Time.now) do
            publisher.publish

            expect(client).to have_received(:put_metric_data).with(
              namespace: "Sidekiq",
              metric_data: include(
                {
                  metric_name: "Utilization",
                  timestamp: now,
                  value: 30.0,
                  unit: "Percent",
                },
                {
                  metric_name: "Utilization",
                  dimensions: [{name: "Hostname", value: "foo"}, {name: "Tag", value: "default"}],
                  timestamp: now,
                  unit: "Percent",
                  value: 50.0,
                },
                {
                  metric_name: "Utilization",
                  dimensions: [{name: "Hostname", value: "bar"}, {name: "Tag", value: "shard-one"}],
                  timestamp: now,
                  unit: "Percent",
                  value: 10.0,
                },
              ),
            )
          end
        end
      end

      context "with custom dimensions" do
        subject(:publisher) { Sidekiq::CloudWatchMetrics::Publisher.new(client: client, additional_dimensions: {appCluster: 1, type: "foo"}) }

        it "publishes metrics with custom dimensions" do
          Timecop.freeze(now = Time.now) do
            publisher.publish

            expect(client).to have_received(:put_metric_data) { |metrics|
              metrics[:metric_data].each do |metric|
                expect(metric[:dimensions]).to include({name: "appCluster", value: "1"}, {name: "type", value: "foo"})
              end
            }.at_least(:once)
          end
        end
      end

      context "with a custom namespace" do
        subject(:publisher) { Sidekiq::CloudWatchMetrics::Publisher.new(client: client, namespace: "Sidekiq-Test") }

        it "publishes metrics with the specified namespace" do
          Timecop.freeze(now = Time.now) do
            publisher.publish

            expect(client).to have_received(:put_metric_data) { |metrics|
              expect(metrics[:namespace]).to eql("Sidekiq-Test")
            }.at_least(:once)
          end
        end
      end

      context "when there are no processes yet" do
        let(:processes) { [] }

        it "does not publish Utilization (to avoid NaN values)" do
          Timecop.freeze(now = Time.now) do
            publisher.publish

            expect(client).to have_received(:put_metric_data) { |metrics|
              expect(metrics[:metric_data]).not_to include(hash_including(metric_name: "Utilization"))
            }
          end
        end
      end

      context "when the only process has no threads yet" do
        let(:processes) { [Sidekiq::Process.new("busy" => 0, "concurrency" => 0, "hostname" => "foo")] }

        it "does not publish Utilization (to avoid NaN values)" do
          Timecop.freeze(now = Time.now) do
            publisher.publish

            expect(client).to have_received(:put_metric_data) { |metrics|
              expect(metrics[:metric_data]).not_to include(hash_including(metric_name: "Utilization"))
            }
          end
        end
      end

      context "when only one process has no threads yet" do
        let(:processes) { [
          Sidekiq::Process.new("busy" => 0, "concurrency" => 0, "hostname" => "foo"),
          Sidekiq::Process.new("busy" => 2, "concurrency" => 4, "hostname" => "bar"),
        ] }

        it "publishes partial Utilization (to avoid NaN values)" do
          Timecop.freeze(now = Time.now) do
            publisher.publish

            expect(client).to have_received(:put_metric_data) { |metrics|
              utilization_data = metrics[:metric_data].select { |data| data[:metric_name] == "Utilization" }

              expect(utilization_data).to contain_exactly(
                {
                  metric_name: "Utilization",
                  timestamp: now,
                  value: 50.0,
                  unit: "Percent",
                },
                {
                  metric_name: "Utilization",
                  dimensions: [{name: "Hostname", value: "bar"}],
                  timestamp: now,
                  unit: "Percent",
                  value: 50.0,
                },
              )
            }
          end
        end
      end

      context "when per process metrics are disabled" do
        subject(:publisher) { Sidekiq::CloudWatchMetrics::Publisher.new(client: client, process_metrics: false) }

        it "only publishes a single Utilization metric" do
          Timecop.freeze(now = Time.now) do
            publisher.publish

            expect(client).to have_received(:put_metric_data) { |metrics|
              utilization_data = metrics[:metric_data].select { |data| data[:metric_name] == "Utilization" }

              expect(utilization_data).to contain_exactly(
                {
                  metric_name: "Utilization",
                  timestamp: now,
                  value: 30.0,
                  unit: "Percent",
                },
              )
            }
          end
        end
      end
    end

    describe "#stop" do
      it "doesn't raise ThreadError" do
        thread = double("thread", wakeup: true, join: true)
        allow(thread).to receive(:wakeup).and_raise(ThreadError)
        publisher.instance_variable_set("@thread", thread)

        expect do
          publisher.stop
        end.not_to raise_error
      end
    end
  end
end
