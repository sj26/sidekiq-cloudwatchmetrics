# frozen_string_literal: true

require "sidekiq/api"

module Sidekiq::CloudWatchMetrics
  class Collector
    def initialize(process_metrics: true, additional_dimensions: {})
      @process_metrics = process_metrics
      @additional_dimensions = additional_dimensions.map { |k, v| {name: k.to_s, value: v.to_s} }
    end

    def collect
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
      ]

      utilization = calculate_utilization(processes) * 100.0

      unless utilization.nan?
        metrics << {
          metric_name: "Utilization",
          timestamp: now,
          value: utilization,
          unit: "Percent",
        }
      end

      processes.group_by do |process|
        process["tag"]
      end.each do |(tag, tag_processes)|
        next if tag.nil?

        tag_utilization = calculate_utilization(tag_processes) * 100.0

        unless tag_utilization.nan?
          metrics << {
            metric_name: "Utilization",
            dimensions: [{name: "Tag", value: tag}],
            timestamp: now,
            value: tag_utilization,
            unit: "Percent",
          }
        end
      end

      if @process_metrics
        processes.each do |process|
          process_utilization = process["busy"] / process["concurrency"].to_f * 100.0

          unless process_utilization.nan?
            process_dimensions = [{name: "Hostname", value: process["hostname"]}]

            if process["tag"]
              process_dimensions << {name: "Tag", value: process["tag"]}
            end

            metrics << {
              metric_name: "Utilization",
              dimensions: process_dimensions,
              timestamp: now,
              value: process_utilization,
              unit: "Percent",
            }
          end
        end
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

      metrics
    end

    # Returns the total number of workers across all processes
    private def calculate_capacity(processes)
      processes.map do |process|
        process["concurrency"]
      end.sum
    end

    # Returns busy / concurrency averaged across processes (for scaling)
    # Avoid considering processes not yet running any threads
    private def calculate_utilization(processes)
      process_utilizations = processes.map do |process|
        process["busy"] / process["concurrency"].to_f
      end.reject(&:nan?)

      process_utilizations.sum / process_utilizations.size.to_f
    end
  end
end
