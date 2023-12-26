# frozen_string_literal: true

require "sidekiq"

require "sidekiq/cloud_watch_metrics/publisher"

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
end
