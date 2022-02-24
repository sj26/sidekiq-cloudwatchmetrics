require "spec_helper"

RSpec.describe Sidekiq::CloudWatchMetrics do
  describe ".enable!" do
    # Sidekiq.options does a Sidekiq::DEFAULTS.dup which retains the same values, so
    # Sidekiq.options[:lifecycle_events] IS Sidekiq::DEFAULTS[:lifecycle_events] and
    # is mutable, so Sidekiq.options = nil will again Sidekiq::DEFAULTS.dup and get
    # the same Sidekiq::DEFAULTS[:lifecycle_events]. So we have to manually clear it.
    before { Sidekiq.options[:lifecycle_events].each_value(&:clear) }

    context "in a sidekiq server" do
      before { allow(Sidekiq).to receive(:server?).and_return(true) }

      it "creates a metrics publisher and installs hooks" do
        publisher = instance_double(Sidekiq::CloudWatchMetrics::Publisher)
        expect(Sidekiq::CloudWatchMetrics::Publisher).to receive(:new).and_return(publisher)

        Sidekiq::CloudWatchMetrics.enable!

        # Look, this is hard.
        expect(Sidekiq.options[:lifecycle_events][:startup]).not_to be_empty
        expect(Sidekiq.options[:lifecycle_events][:quiet]).not_to be_empty
        expect(Sidekiq.options[:lifecycle_events][:shutdown]).not_to be_empty
      end
    end

    context "in client mode" do
      before { allow(Sidekiq).to receive(:server?).and_return(false) }

      it "does nothing" do
        expect(Sidekiq::CloudWatchMetrics::Publisher).not_to receive(:new)

        Sidekiq::CloudWatchMetrics.enable!

        expect(Sidekiq.options[:lifecycle_events][:startup]).to be_empty
        expect(Sidekiq.options[:lifecycle_events][:quiet]).to be_empty
        expect(Sidekiq.options[:lifecycle_events][:shutdown]).to be_empty
      end
    end
  end

  describe "Publisher" do
    let(:client) { instance_double(Aws::CloudWatch::Client) }
    before { allow(client).to receive(:put_metric_data) }

    subject(:publisher) { Sidekiq::CloudWatchMetrics::Publisher.new(client: client) }

    RSpec.shared_examples 'publishing sidekiq metrics to cloudwatch' do |options = {}|
      it "publishes sidekiq metrics to cloudwatch under the #{options.fetch(:expected_namespace)} namespace" do
        Timecop.freeze(now = Time.now) do
          stats = instance_double(Sidekiq::Stats,
            processed: 123,
            failed: 456,
            enqueued: 6,
            scheduled_size: 1,
            retry_size: 2,
            dead_size: 3,
            queues: {"foo" => 1, "bar" => 2, "baz" => 3},
            workers_size: 10,
            processes_size: 5,
            default_queue_latency: 1.23,
          )
          allow(Sidekiq::Stats).to receive(:new).and_return(stats)
          processes = [
            Sidekiq::Process.new("busy" => 5, "concurrency" => 10, "hostname" => "foo", "tag" => "sidekiq-high"),
            Sidekiq::Process.new("busy" => 2, "concurrency" => 20, "hostname" => "bar", "tag" => "sidekiq-low"),
          ]
          allow(Sidekiq::ProcessSet).to receive(:new).and_return(processes)
          allow(Sidekiq::Queue).to receive(:new).with(/foo|bar|baz/).and_return(double(latency: 1.23))


          expect(client).to receive(:put_metric_data).ordered.with(
            namespace: options.fetch(:expected_namespace),
            metric_data: contain_exactly(
              {
                metric_name: "ProcessedJobs",
                timestamp: now,
                value: stats.processed,
                unit: "Count",
              },
              {
                metric_name: "FailedJobs",
                timestamp: now,
                value: stats.failed,
                unit: "Count",
              },
              {
                metric_name: "EnqueuedJobs",
                timestamp: now,
                value: stats.enqueued,
                unit: "Count",
              },
              {
                metric_name: "ScheduledJobs",
                timestamp: now,
                value: stats.scheduled_size,
                unit: "Count",
              },
              {
                metric_name: "RetryJobs",
                timestamp: now,
                value: stats.retry_size,
                unit: "Count",
              },
              {
                metric_name: "DeadJobs",
                timestamp: now,
                value: stats.dead_size,
                unit: "Count",
              },
              {
                metric_name: "Workers",
                timestamp: now,
                value: stats.workers_size,
                unit: "Count",
              },
              {
                metric_name: "Processes",
                timestamp: now,
                value: stats.processes_size,
                unit: "Count",
              },
              {
                metric_name: "Capacity",
                timestamp: now,
                value: 30,
                unit: "Count",
              },
              {
                metric_name: "Utilization",
                timestamp: now,
                value: 30.0,
                unit: "Percent",
              },
              {
                metric_name: "DefaultQueueLatency",
                timestamp: now,
                value: stats.default_queue_latency,
                unit: "Seconds",
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
                dimensions: [{name: "Tag", value: "sidekiq-high"}],
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
                metric_name: "Utilization",
                dimensions: [{name: "Tag", value: "sidekiq-low"}],
                timestamp: now,
                unit: "Percent",
                value: 10.0,
              },
              {
                metric_name: "QueueSize",
                dimensions: [{name: "QueueName", value: "foo"}],
                timestamp: now,
                value: stats.queues["foo"],
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
                value: stats.queues["bar"],
                unit: "Count",
              },
              {
                metric_name: "QueueLatency",
                dimensions: [{name: "QueueName", value: "bar"}],
                timestamp: now,
                value: 1.23,
                unit: "Seconds",
              },
              {
                metric_name: "QueueSize",
                dimensions: [{name: "QueueName", value: "baz"}],
                timestamp: now,
                value: stats.queues["baz"],
                unit: "Count",
              },
            ),
          )

          expect(client).to receive(:put_metric_data).ordered.with(
            namespace: options.fetch(:expected_namespace),
            metric_data: contain_exactly(
              {
                metric_name: "QueueLatency",
                dimensions: [{name: "QueueName", value: "baz"}],
                timestamp: now,
                value: 1.23,
                unit: "Seconds",
              },
            ),
          )

          publisher.publish
        end
      end
    end

    describe "#publish" do
      include_examples 'publishing sidekiq metrics to cloudwatch', expected_namespace: 'Sidekiq'

      context 'with a custom namespace' do
        subject(:publisher) { Sidekiq::CloudWatchMetrics::Publisher.new(client: client, namespace: 'Sidekiq-Test') }

        include_examples 'publishing sidekiq metrics to cloudwatch', expected_namespace: 'Sidekiq-Test'
      end

      it "publishes custom dimensions" do
        Timecop.freeze(now = Time.now) do
          stats = instance_double(Sidekiq::Stats,
            processed: 123,
            failed: 456,
            enqueued: 6,
            scheduled_size: 1,
            retry_size: 2,
            dead_size: 3,
            queues: {"foo" => 1, "bar" => 2, "baz" => 3},
            workers_size: 10,
            processes_size: 5,
            default_queue_latency: 1.23,
          )
          allow(Sidekiq::Stats).to receive(:new).and_return(stats)
          processes = [
            Sidekiq::Process.new("busy" => 5, "concurrency" => 10, "hostname" => "foo", "tag" => "sidekiq-high"),
            Sidekiq::Process.new("busy" => 2, "concurrency" => 20, "hostname" => "bar", "tag" => "sidekiq-low"),
          ]
          allow(Sidekiq::ProcessSet).to receive(:new).and_return(processes)
          allow(Sidekiq::Queue).to receive(:new).with(/foo|bar|baz/).and_return(double(latency: 1.23))

          publisher_with_custom_dimensions = 
            Sidekiq::CloudWatchMetrics::Publisher.new(client: client, additional_dimensions: {appCluster: 1, type: "foo"})

          expect(client).to receive(:put_metric_data).ordered.with(
            namespace: "Sidekiq",
            metric_data: contain_exactly(
              {
                metric_name: "ProcessedJobs",
                timestamp: now,
                value: stats.processed,
                unit: "Count",
                dimensions: [{name: "appCluster", value: "1"},
                             {name: "type", value: "foo"}],
              },
              {
                metric_name: "FailedJobs",
                timestamp: now,
                value: stats.failed,
                unit: "Count",
                dimensions: [{name: "appCluster", value: "1"},
                             {name: "type", value: "foo"}],
              },
              {
                metric_name: "EnqueuedJobs",
                timestamp: now,
                value: stats.enqueued,
                unit: "Count",
                dimensions: [{name: "appCluster", value: "1"},
                             {name: "type", value: "foo"}],
              },
              {
                metric_name: "ScheduledJobs",
                timestamp: now,
                value: stats.scheduled_size,
                unit: "Count",
                dimensions: [{name: "appCluster", value: "1"},
                             {name: "type", value: "foo"}],
              },
              {
                metric_name: "RetryJobs",
                timestamp: now,
                value: stats.retry_size,
                unit: "Count",
                dimensions: [{name: "appCluster", value: "1"},
                             {name: "type", value: "foo"}],
              },
              {
                metric_name: "DeadJobs",
                timestamp: now,
                value: stats.dead_size,
                unit: "Count",
                dimensions: [{name: "appCluster", value: "1"},
                             {name: "type", value: "foo"}],
              },
              {
                metric_name: "Workers",
                timestamp: now,
                value: stats.workers_size,
                unit: "Count",
                dimensions: [{name: "appCluster", value: "1"},
                             {name: "type", value: "foo"}],
              },
              {
                metric_name: "Processes",
                timestamp: now,
                value: stats.processes_size,
                unit: "Count",
                dimensions: [{name: "appCluster", value: "1"},
                             {name: "type", value: "foo"}],
              },
              {
                metric_name: "Capacity",
                timestamp: now,
                value: 30,
                unit: "Count",
                dimensions: [{name: "appCluster", value: "1"},
                             {name: "type", value: "foo"}],
              },
              {
                metric_name: "Utilization",
                timestamp: now,
                value: 30.0,
                unit: "Percent",
                dimensions: [{name: "appCluster", value: "1"},
                             {name: "type", value: "foo"}],
              },
              {
                metric_name: "DefaultQueueLatency",
                timestamp: now,
                value: stats.default_queue_latency,
                unit: "Seconds",
                dimensions: [{name: "appCluster", value: "1"},
                             {name: "type", value: "foo"}],
              },
              {
                metric_name: "Utilization",
                dimensions: [{name: "Hostname", value: "foo"},
                             {name: "appCluster", value: "1"},
                             {name: "type", value: "foo"}],
                timestamp: now,
                unit: "Percent",
                value: 50.0,
              },
              {
                metric_name: "Utilization",
                dimensions: [{name: "Tag", value: "sidekiq-high"},
                             {name: "appCluster", value: "1"},
                             {name: "type", value: "foo"}],
                timestamp: now,
                unit: "Percent",
                value: 50.0,
              },
              {
                metric_name: "Utilization",
                dimensions: [{name: "Hostname", value: "bar"},
                             {name: "appCluster", value: "1"},
                             {name: "type", value: "foo"}],
                timestamp: now,
                unit: "Percent",
                value: 10.0,
              },
              {
                metric_name: "Utilization",
                dimensions: [{name: "Tag", value: "sidekiq-low"},
                             {name: "appCluster", value: "1"},
                             {name: "type", value: "foo"}],
                timestamp: now,
                unit: "Percent",
                value: 10.0,
              },
              {
                metric_name: "QueueSize",
                dimensions: [{name: "QueueName", value: "foo"},
                             {name: "appCluster", value: "1"},
                             {name: "type", value: "foo"}],
                timestamp: now,
                value: stats.queues["foo"],
                unit: "Count",
              },
              {
                metric_name: "QueueLatency",
                dimensions: [{name: "QueueName", value: "foo"},
                             {name: "appCluster", value: "1"},
                             {name: "type", value: "foo"}],
                timestamp: now,
                value: 1.23,
                unit: "Seconds",
              },
              {
                metric_name: "QueueSize",
                dimensions: [{name: "QueueName", value: "bar"},
                             {name: "appCluster", value: "1"},
                             {name: "type", value: "foo"}],
                timestamp: now,
                value: stats.queues["bar"],
                unit: "Count",
              },
              {
                metric_name: "QueueLatency",
                dimensions: [{name: "QueueName", value: "bar"},
                             {name: "appCluster", value: "1"},
                             {name: "type", value: "foo"}],
                timestamp: now,
                value: 1.23,
                unit: "Seconds",
              },
              {
                metric_name: "QueueSize",
                dimensions: [{name: "QueueName", value: "baz"},
                             {name: "appCluster", value: "1"},
                             {name: "type", value: "foo"}],
                timestamp: now,
                value: stats.queues["baz"],
                unit: "Count",
              }
            ),
          )

          expect(client).to receive(:put_metric_data).ordered.with(
            namespace: "Sidekiq",
            metric_data: contain_exactly(
              {
                metric_name: "QueueLatency",
                dimensions: [{name: "QueueName", value: "baz"},
                             {name: "appCluster", value: "1"},
                             {name: "type", value: "foo"}],
                timestamp: now,
                value: 1.23,
                unit: "Seconds",
              }
            ),
          )

          publisher_with_custom_dimensions.publish
        end
      end

      it "publishes sidekiq metrics to cloudwatch for lots of queues in batches of 20" do
        Timecop.freeze(now = Time.now) do
          stats = instance_double(Sidekiq::Stats,
            processed: 123,
            failed: 456,
            enqueued: 6,
            scheduled_size: 1,
            retry_size: 2,
            dead_size: 3,
            queues: 30.times.each_with_object({}) { |i, hash| hash["queue#{i}"] = i },
            workers_size: 10,
            processes_size: 5,
            default_queue_latency: 1.23,
          )
          allow(Sidekiq::Stats).to receive(:new).and_return(stats)
          allow(Sidekiq::Queue).to receive(:new).with(/queue\d/).and_return(double(latency: 1.23))

          publisher.publish

          expect(client).to have_received(:put_metric_data).exactly(4).times
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
