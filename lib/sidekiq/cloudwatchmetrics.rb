# frozen_string_literal: true

require "sidekiq"
require "sidekiq/api"

require "aws-sdk-cloudwatch"

require_relative 'cloud_watch_metrics/collector'

module Sidekiq::CloudWatchMetrics
  def self.enable!(**kwargs)
    Sidekiq.configure_server do |config|
      publisher = Publisher.new(**kwargs)

      # Sidekiq enterprise has a globally unique leader thread, making it
      # easier to publish the cluster-wide metrics from one place.
      if defined?(Sidekiq::Enterprise)
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
    begin
      require "sidekiq/util"
      include Sidekiq::Util
    rescue LoadError
      # Sidekiq 6.5 refactored to use Sidekiq::Component
      require "sidekiq/component"
      include Sidekiq::Component
    end

    INTERVAL = 60 # seconds

    def initialize(config: Sidekiq,
                   client: Aws::CloudWatch::Client.new,
                   namespace: "Sidekiq",
                   collector: nil,
                   process_metrics: true,
                   additional_dimensions: {})
      # Sidekiq 6.5+ requires @config, which defaults to the top-level
      # `Sidekiq` module, but can be overridden when running multiple Sidekiqs.
      @config = config
      @client = client
      @namespace = namespace
      @collector = collector ||
        Sidekiq::CloudWatchMetrics::Collector.new(
          process_metrics: process_metrics,
          additional_dimensions: additional_dimensions
        )
    end

    def start
      logger.debug { "Starting Sidekiq CloudWatch Metrics Publisher" }

      @done = false
      @thread = safe_thread("cloudwatch metrics publisher", &method(:run))
    end

    def running?
      !@thread.nil? && @thread.alive?
    end

    def run
      logger.info { "Started Sidekiq CloudWatch Metrics Publisher" }

      # Publish stats every INTERVAL seconds, sleeping as required between runs
      now = Time.now.to_f
      tick = now
      until @stop
        logger.debug { "Publishing Sidekiq CloudWatch Metrics" }
        publish

        now = Time.now.to_f
        tick = [tick + INTERVAL, now].max
        sleep(tick - now) if tick > now
      end

      logger.debug { "Stopped Sidekiq CloudWatch Metrics Publisher" }
    end

    def publish
      metrics = @collector.collect

      # We can only put 20 metrics at a time
      metrics.each_slice(20) do |some_metrics|
        @client.put_metric_data(
          namespace: @namespace,
          metric_data: some_metrics,
          )
      end
    end

    def quiet
      logger.debug { "Quieting Sidekiq CloudWatch Metrics Publisher" }
      @stop = true
    end

    def stop
      logger.debug { "Stopping Sidekiq CloudWatch Metrics Publisher" }
      @stop = true
      @thread.wakeup
      @thread.join
    rescue ThreadError
      # Don't raise if thread is already dead.
      nil
    end
  end
end
