# frozen_string_literal: true

require "sidekiq"
require "sidekiq/api"
require "sidekiq/manager"

require "aws-sdk-cloudwatch"

module Sidekiq::CloudWatchMetrics
  def self.enable!(**kwargs)
    Sidekiq.configure_server do |config|
      publisher = Publisher.new(**kwargs)

      if Sidekiq.options[:lifecycle_events].has_key?(:leader)
        # Only publish metrics on the leader if we have a leader (sidekiq-ent)
        config.on(:leader) do
          publisher.start
        end
      else
        # Otherwise pubishing from every node doesn't hurt, it's just wasteful
        config.on(:startup) do
          publisher.start
        end
      end

      config.on(:quiet) do
        publisher.quiet if publisher.running?
      end

      config.on(:shutdown) do
        publisher.stop if publisher.running?
      end
    end
  end

  class Publisher
    include Sidekiq::Component

    INTERVAL = 60 # seconds

    def initialize(client: Aws::CloudWatch::Client.new, namespace: "Sidekiq", additional_dimensions: {})
      @client = client
      @namespace = namespace
      @additional_dimensions = additional_dimensions.map { |k, v| {name: k.to_s, value: v.to_s} }
    end

    def start
      Sidekiq.logger.info { "Starting Sidekiq CloudWatch Metrics Publisher" }

      @done = false
      @thread = safe_thread("cloudwatch metrics publisher", &method(:run))
    end

    def running?
      !@thread.nil? && @thread.alive?
    end

    def run
      Sidekiq.logger.info { "Started Sidekiq CloudWatch Metrics Publisher" }

      # Publish stats every INTERVAL seconds, sleeping as required between runs
      now = Time.now.to_f
      tick = now
      until @stop
        Sidekiq.logger.info { "Publishing Sidekiq CloudWatch Metrics" }
        publish

        now = Time.now.to_f
        tick = [tick + INTERVAL, now].max
        sleep(tick - now) if tick > now
      end

      Sidekiq.logger.info { "Stopped Sidekiq CloudWatch Metrics Publisher" }
    end

    def publish
      now = Time.now
      stats = Sidekiq::Stats.new
      processes = Sidekiq::ProcessSet.new.to_enum(:each).to_a
      queues = stats.queues

      metrics = [
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
          metric_name: "DefaultQueueLatency",
          timestamp: now,
          value: stats.default_queue_latency,
          unit: "Seconds",
        },
        {
          metric_name: "Capacity",
          timestamp: now,
          value: calculate_capacity(processes),
          unit: "Count",
        },
        {
          metric_name: "Utilization",
          timestamp: now,
          value: calculate_utilization(processes) * 100.0,
          unit: "Percent",
        },
      ]

      processes.each do |process|
        metrics << {
          metric_name: "Utilization",
          dimensions: [{name: "Hostname", value: process["hostname"]}],
          timestamp: now,
          value: to_factor(process["busy"], process["concurrency"]) * 100.0,
          unit: "Percent",
        }

        metrics << {
          metric_name: "Utilization",
          dimensions: [{name: "Tag", value: process["tag"]}],
          timestamp: now,
          value: to_factor(process["busy"], process["concurrency"]) * 100.0,
          unit: "Percent",
        }
      end

      queues.each do |(queue_name, queue_size)|
        metrics << {
          metric_name: "QueueSize",
          dimensions: [{name: "QueueName", value: queue_name}],
          timestamp: now,
          value: queue_size,
          unit: "Count",
        }

        queue_latency = Sidekiq::Queue.new(queue_name).latency

        metrics << {
          metric_name: "QueueLatency",
          dimensions: [{name: "QueueName", value: queue_name}],
          timestamp: now,
          value: queue_latency,
          unit: "Seconds",
        }
      end

      unless @additional_dimensions.empty?
        metrics = metrics.each do |metric|
          metric[:dimensions] = (metric[:dimensions] || []) + @additional_dimensions
        end
      end
      # We can only put 20 metrics at a time
      metrics.each_slice(20) do |some_metrics|
        @client.put_metric_data(
          namespace: @namespace,
          metric_data: some_metrics,
        )
      end
    end

    # Returns the total number of workers across all processes
    private def calculate_capacity(processes)
      processes.map do |process|
        process["concurrency"]
      end.sum.to_f
    end

    # Returns busy / concurrency averaged across processes (for scaling)
    private def calculate_utilization(processes)
      # If no processes are available return 0
      return 0.0 if processes.size.zero?

      processes.map do |process|
        to_factor(process["busy"], process["concurrency"])
      end.sum / processes.size.to_f
    end

    private def to_factor(inp1, inp2)
      return 0.0 if inp2.zero?

      inp1 / inp2.to_f
    end

    def quiet
      Sidekiq.logger.info { "Quieting Sidekiq CloudWatch Metrics Publisher" }
      @stop = true
    end

    def stop
      Sidekiq.logger.info { "Stopping Sidekiq CloudWatch Metrics Publisher" }
      @stop = true
      @thread.wakeup
      @thread.join
    rescue ThreadError
      # Don't raise if thread is already dead.
      nil
    end
  end
end
