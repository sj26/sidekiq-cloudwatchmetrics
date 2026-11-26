require "spec_helper"

require "fiber"

RSpec.describe Sidekiq::CloudWatchMetrics do
  describe "MetricsConfig" do
    subject(:config) { Sidekiq::CloudWatchMetrics::MetricsConfig.new }

    describe "#initialize" do
      it "starts with all metrics enabled by default" do
        expect(config.all_enabled?).to be true
        expect(config.metric_enabled?(:processed_jobs)).to be true
        expect(config.metric_enabled?(:any_random_metric)).to be true
      end
    end

    describe "#enable_metric" do
      it "switches to opt-in mode and enables specific metric" do
        config.enable_metric(:queue_size)
        expect(config.all_enabled?).to be false
        expect(config.metric_enabled?(:queue_size)).to be true
        expect(config.metric_enabled?(:processed_jobs)).to be false
      end

      it "accepts string or symbol" do
        config.enable_metric("queue_size")
        expect(config.metric_enabled?(:queue_size)).to be true
      end
    end

    describe "#enable_metrics" do
      it "enables multiple metrics at once" do
        config.enable_metrics(:queue_size, :queue_latency, :utilization)
        expect(config.metric_enabled?(:queue_size)).to be true
        expect(config.metric_enabled?(:queue_latency)).to be true
        expect(config.metric_enabled?(:utilization)).to be true
        expect(config.metric_enabled?(:processed_jobs)).to be false
      end

      it "rejects unknown metrics without changing the selection" do
        expect { config.enable_metrics(:queue_size, "queue_szie") }
          .to raise_error(ArgumentError, /queue_szie/)

        expect(config.metric_enabled?(:processed_jobs)).to be true
      end
    end

    describe "#register_custom_metrics" do
      it "registers custom metrics without changing the enabled metrics" do
        block = proc { [] }
        config.register_custom_metrics(&block)

        expect(config.custom_metrics).to eq([block])
        expect(config.all_enabled?).to be true
      end

      it "requires a block" do
        expect { config.register_custom_metrics }.to raise_error(ArgumentError)
      end
    end

    describe "#to_s" do
      it "shows default message when all enabled" do
        expect(config.to_s).to eq("All metrics enabled (default)")
      end

      it "shows enabled metrics when in opt-in mode" do
        config.enable_metrics(:capacity, :queue_size, :utilization)
        expect(config.to_s).to eq("Enabled metrics: capacity, queue_size, utilization")
      end
    end
  end

  describe ".configure" do
    before { Sidekiq::CloudWatchMetrics.metrics_config = nil }

    it "yields a MetricsConfig instance" do
      Sidekiq::CloudWatchMetrics.configure do |config|
        expect(config).to be_a(Sidekiq::CloudWatchMetrics::MetricsConfig)
      end
    end

    it "saves the configuration" do
      Sidekiq::CloudWatchMetrics.configure do |config|
        config.enable_metric(:queue_size)
      end

      expect(Sidekiq::CloudWatchMetrics.metrics_config.metric_enabled?(:queue_size)).to be true
      expect(Sidekiq::CloudWatchMetrics.metrics_config.metric_enabled?(:processed_jobs)).to be false
    end

    it "returns the configuration" do
      result = Sidekiq::CloudWatchMetrics.configure do |config|
        config.enable_metric(:queue_size)
      end

      expect(result).to be_a(Sidekiq::CloudWatchMetrics::MetricsConfig)
      expect(result.metric_enabled?(:queue_size)).to be true
    end
  end

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

    let(:custom_config) do
      config = Sidekiq::CloudWatchMetrics::MetricsConfig.new
      config.enable_metrics(:queue_size, :queue_latency, :utilization)
      config
    end

    describe "#run" do
      it "publishes metrics until stopped" do
        allow(publisher).to receive(:sleep) { |seconds| Fiber.yield(:sleep, seconds) }
        allow(publisher).to receive(:publish) { Fiber.yield(:publish) }

        fiber = Fiber.new { publisher.run }
        expect(fiber.resume).to eql(:publish)
        expect(fiber.resume).to match([:sleep, be_a_kind_of(Numeric) & (be < Sidekiq::CloudWatchMetrics::Publisher::DEFAULT_INTERVAL)])
        expect(fiber.resume).to eql(:publish)
        expect(fiber.resume).to match([:sleep, be_a_kind_of(Numeric) & (be < (Sidekiq::CloudWatchMetrics::Publisher::DEFAULT_INTERVAL * 2))])

        publisher.stop
        fiber.resume
        expect(fiber).not_to be_alive
      end

      context "with a custom interval" do
        subject(:publisher) { Sidekiq::CloudWatchMetrics::Publisher.new(client: client, interval: 30) }

        it "respects a custom interval" do
          allow(publisher).to receive(:sleep) { |seconds| Fiber.yield(:sleep, seconds) }
          allow(publisher).to receive(:publish) { Fiber.yield(:publish) }

          fiber = Fiber.new { publisher.run }
          expect(fiber.resume).to eql(:publish)
          expect(fiber.resume).to match([:sleep, be_a_kind_of(Numeric) & (be < 30)])

          publisher.stop
          fiber.resume
          expect(fiber).not_to be_alive
        end
      end

      it "survives an error raised during publishing" do
        allow(publisher).to receive(:sleep) { |seconds| Fiber.yield(:sleep) }

        exception = RuntimeError.new("oh no")
        allow(publisher).to receive(:publish).and_invoke(lambda { raise exception }, lambda { Fiber.yield(:publish) })
        allow(publisher).to receive(:handle_exception) { |exception| Fiber.yield(:exception, exception) }

        fiber = Fiber.new { publisher.run }
        expect(fiber.resume).to eql([:exception, exception])
        expect(fiber.resume).to eql(:sleep)
        expect(fiber.resume).to eql(:publish)
        expect(fiber.resume).to eql(:sleep)

        publisher.stop
        fiber.resume
        expect(fiber).not_to be_alive
      end
    end

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

      context "with a custom interval of less than 60" do
        subject(:publisher) { Sidekiq::CloudWatchMetrics::Publisher.new(client: client, interval: 30) }

        it "passes sets a storage resolution of 1" do
          Timecop.freeze(now = Time.now) do
            publisher.publish

            expect(client).to have_received(:put_metric_data).with(
              namespace: "Sidekiq",
              metric_data: including(
                {
                  metric_name: "ProcessedJobs",
                  timestamp: now,
                  value: 123,
                  unit: "Count",
                  storage_resolution: 1,
                },
                {
                  metric_name: "FailedJobs",
                  timestamp: now,
                  value: 456,
                  unit: "Count",
                  storage_resolution: 1,
                },
                {
                  metric_name: "QueueSize",
                  dimensions: [{name: "QueueName", value: "bar"}],
                  timestamp: now,
                  value: 2,
                  unit: "Count",
                  storage_resolution: 1,
                },
                {
                  metric_name: "QueueLatency",
                  dimensions: [{name: "QueueName", value: "bar"}],
                  timestamp: now,
                  value: 1.23,
                  unit: "Seconds",
                  storage_resolution: 1,
                },
              )
            )
          end
        end
      end

      context "with a custom interval of more than 60" do
        subject(:publisher) { Sidekiq::CloudWatchMetrics::Publisher.new(client: client, interval: 120) }

        it "doesn't pass a storage resolution" do
          Timecop.freeze(now = Time.now) do
            publisher.publish

            expect(client).to have_received(:put_metric_data).with(
              namespace: "Sidekiq",
              metric_data: including(
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
              )
            )
          end
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
            Sidekiq::Process.new("busy" => 5, "concurrency" => 5, "hostname" => "foo", "tag" => "default"),
            Sidekiq::Process.new("busy" => 2, "concurrency" => 20, "hostname" => "bar", "tag" => "shard-one"),
            Sidekiq::Process.new("busy" => 0, "concurrency" => 5, "hostname" => "baz", "tag" => "default"),
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
                  value: 36.66666666666667,
                  unit: "Percent",
                },
                {
                  metric_name: "Capacity",
                  dimensions: [{name: "Tag", value: "default"}],
                  timestamp: now,
                  unit: "Count",
                  value: 10,
                },
                {
                  metric_name: "Utilization",
                  dimensions: [{name: "Tag", value: "default"}],
                  timestamp: now,
                  value: 50.0,
                  unit: "Percent",
                },
                {
                  metric_name: "Capacity",
                  dimensions: [{name: "Tag", value: "shard-one"}],
                  timestamp: now,
                  unit: "Count",
                  value: 20,
                },
                {
                  metric_name: "Utilization",
                  dimensions: [{name: "Tag", value: "shard-one"}],
                  timestamp: now,
                  value: 10.0,
                  unit: "Percent",
                },
                {
                  metric_name: "Utilization",
                  dimensions: [{name: "Hostname", value: "foo"}, {name: "Tag", value: "default"}],
                  timestamp: now,
                  unit: "Percent",
                  value: 100.0,
                },
                {
                  metric_name: "Utilization",
                  dimensions: [{name: "Hostname", value: "bar"}, {name: "Tag", value: "shard-one"}],
                  timestamp: now,
                  unit: "Percent",
                  value: 10.0,
                },
                {
                  metric_name: "Utilization",
                  dimensions: [{name: "Hostname", value: "baz"}, {name: "Tag", value: "default"}],
                  timestamp: now,
                  unit: "Percent",
                  value: 0.0,
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

      context "with custom metrics" do
        let(:metrics_config) do
          config = Sidekiq::CloudWatchMetrics::MetricsConfig.new
          config.register_custom_metrics do |timestamp, stats, processes|
            [
              {
                metric_name: "Custom",
                dimensions: [{name: "Foo", value: "bar"}],
                timestamp: timestamp,
                value: stats.processed + processes.size,
                unit: "Count",
              },
            ]
          end
          config.register_custom_metrics do |timestamp|
            [
              {
                metric_name: "TimestampOnly",
                timestamp: timestamp,
                value: 1,
                unit: "Count",
              },
            ]
          end
          config
        end

        subject(:publisher) { Sidekiq::CloudWatchMetrics::Publisher.new(client: client, metrics_config: metrics_config, additional_dimensions: {appCluster: 1}) }

        it "publishes the custom metrics with the additional dimensions" do
          Timecop.freeze(now = Time.now) do
            publisher.publish

            expect(client).to have_received(:put_metric_data).with(
              namespace: "Sidekiq",
              metric_data: include(
                {
                  metric_name: "Custom",
                  dimensions: [{name: "Foo", value: "bar"}, {name: "appCluster", value: "1"}],
                  timestamp: now,
                  value: 125,
                  unit: "Count",
                },
                {
                  metric_name: "TimestampOnly",
                  dimensions: [{name: "appCluster", value: "1"}],
                  timestamp: now,
                  value: 1,
                  unit: "Count",
                },
              ),
            )
          end
        end
      end

      context "with custom metrics configuration" do
        subject(:publisher) { Sidekiq::CloudWatchMetrics::Publisher.new(client: client, metrics_config: custom_config) }

        it "only publishes enabled metrics" do
          Timecop.freeze(now = Time.now) do
            publisher.publish

            expect(client).to have_received(:put_metric_data) do |args|
              metric_names = args[:metric_data].map { |m| m[:metric_name] }.uniq
              
              # Should include enabled metrics
              expect(metric_names).to include("QueueSize")
              expect(metric_names).to include("QueueLatency")
              expect(metric_names).to include("Utilization")
              
              # Should NOT include disabled metrics
              expect(metric_names).not_to include("ProcessedJobs")
              expect(metric_names).not_to include("FailedJobs")
              expect(metric_names).not_to include("EnqueuedJobs")
              expect(metric_names).not_to include("Workers")
              expect(metric_names).not_to include("Processes")
            end
          end
        end

        it "logs the configuration on startup" do
          allow(publisher).to receive(:sleep) { |seconds| Fiber.yield(:sleep, seconds) }
          allow(publisher).to receive(:publish) { Fiber.yield(:publish) }
          
          logger = double("logger")
          allow(publisher).to receive(:logger).and_return(logger)
          expect(logger).to receive(:info).twice
          expect(logger).to receive(:debug).at_least(:once)
          
          fiber = Fiber.new { publisher.run }
          expect(fiber.resume).to eql(:publish)
          
          publisher.stop
          fiber.resume rescue nil
        end
      end

      context "with queue metrics enabled" do
        let(:queue_config) do
          config = Sidekiq::CloudWatchMetrics::MetricsConfig.new
          config.enable_metrics(:queue_size, :queue_latency)
          config
        end
        
        subject(:publisher) { Sidekiq::CloudWatchMetrics::Publisher.new(client: client, metrics_config: queue_config) }

        it "publishes both queue size and latency metrics" do
          Timecop.freeze(now = Time.now) do
            publisher.publish

            expect(client).to have_received(:put_metric_data).with(
              namespace: "Sidekiq",
              metric_data: contain_exactly(
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
      end

      context "with no configuration (backward compatibility)" do
        it "publishes all metrics by default" do
          Timecop.freeze(now = Time.now) do
            publisher.publish

            expect(client).to have_received(:put_metric_data) do |args|
              metric_names = args[:metric_data].map { |m| m[:metric_name] }.uniq
              
              # Should include all metrics
              expect(metric_names).to include("ProcessedJobs")
              expect(metric_names).to include("FailedJobs")
              expect(metric_names).to include("QueueSize")
              expect(metric_names).to include("QueueLatency")
              expect(metric_names).to include("Utilization")
            end
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
