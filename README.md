# Sidekiq CloudWatch Metrics

Runs a thread inside your Sidekiq processes to report metrics to CloudWatch
useful for autoscaling and keeping an eye on your queues.

Optimised for Sidekiq Enterprise with leader election, but works everywhere!

<img width="1055" alt="Screenshot of Sidekiq metrics in a CloudWatch dashboard" src="https://user-images.githubusercontent.com/14028/44190767-9fd66280-a16b-11e8-8b12-3d5e0641c15f.png">

## Installation

Add this gem to your application’s Gemfile near sidekiq and then run `bundle install`:

```ruby
gem "sidekiq"
gem "sidekiq-cloudwatchmetrics"
```

## Usage

Add near your Sidekiq configuration, like in `config/initializers/sidekiq.rb` in Rails:

```ruby
require "sidekiq"
require "sidekiq/cloudwatchmetrics"

Sidekiq::CloudWatchMetrics.enable!
```

### Configuration

By default, all metrics are published to CloudWatch. If you want to reduce costs by only publishing specific metrics, you can configure which metrics to enable using an opt-in approach:

```ruby
# config/initializers/sidekiq.rb
require "sidekiq"
require "sidekiq/cloudwatchmetrics"

# Configure which metrics to publish (opt-in)
Sidekiq::CloudWatchMetrics.configure do |config|
  # Enable only the metrics you need
  config.enable_metric :queue_size      # Enable QueueSize metric
  config.enable_metric :queue_latency   # Enable QueueLatency metric
  config.enable_metric :utilization     # Enable Utilization metric
  
  # Or enable multiple metrics at once
  config.enable_metrics :capacity, :processes
end

# Then enable CloudWatch metrics with your options
Sidekiq::CloudWatchMetrics.enable!(
  namespace: "Sidekiq-Production",
  interval: 60
)
```

#### Available Metrics

Unknown metric keys raise `ArgumentError` when you configure them.

| Metric Key | CloudWatch Metric Name | Description |
|------------|----------------------|-------------|
| `:processed_jobs` | ProcessedJobs | Total number of processed jobs |
| `:failed_jobs` | FailedJobs | Total number of failed jobs |
| `:enqueued_jobs` | EnqueuedJobs | Number of jobs currently enqueued |
| `:scheduled_jobs` | ScheduledJobs | Number of jobs scheduled for future |
| `:retry_jobs` | RetryJobs | Number of jobs pending retry |
| `:dead_jobs` | DeadJobs | Number of jobs in the dead set |
| `:queue_size` | QueueSize | Size of each queue (per queue metric) |
| `:queue_latency` | QueueLatency | Latency of each queue in seconds (per queue metric) |
| `:default_queue_latency` | DefaultQueueLatency | Overall queue latency |
| `:workers` | Workers | Number of busy workers |
| `:processes` | Processes | Number of Sidekiq processes |
| `:capacity` | Capacity | Total worker capacity |
| `:utilization` | Utilization | Percentage utilization (busy/capacity) |

#### Common Configuration Examples

##### For Autoscaling by Queue Metrics
If you're using CloudWatch metrics for autoscaling based on queue size or latency:

```ruby
Sidekiq::CloudWatchMetrics.configure do |config|
  config.enable_metrics :queue_size, :queue_latency
end

Sidekiq::CloudWatchMetrics.enable!
```

##### For Process Monitoring
Focus on process health and utilization metrics:

```ruby
Sidekiq::CloudWatchMetrics.configure do |config|
  config.enable_metrics :utilization, :capacity, :processes, :workers
end

Sidekiq::CloudWatchMetrics.enable!
```

##### For Job Processing Tracking
Track job processing statistics:

```ruby
Sidekiq::CloudWatchMetrics.configure do |config|
  config.enable_metrics :processed_jobs, :failed_jobs, :retry_jobs, :dead_jobs
end

Sidekiq::CloudWatchMetrics.enable!
```

##### Minimal Setup for Cost Savings
If you only need specific metrics for autoscaling:

```ruby
Sidekiq::CloudWatchMetrics.configure do |config|
  # Only enable the exact metrics your autoscaling policies use
  config.enable_metrics :queue_size, :queue_latency, :utilization
end

Sidekiq::CloudWatchMetrics.enable!(namespace: "Sidekiq-Production")
```

#### Custom Metrics

You can register custom metrics to publish alongside the built-in ones. The block is called on every publish with the timestamp, the `Sidekiq::Stats`, and the processes and queue sizes (a hash of queue name to size) the built-in metrics were collected from, and should return an array of [metric data][metricdata]. Custom metrics also get any `additional_dimensions`:

```ruby
Sidekiq::CloudWatchMetrics.configure do |config|
  # Publish the memory usage of each Sidekiq process
  config.register_custom_metrics do |timestamp, _stats, processes, _queues|
    processes.map do |process|
      {
        metric_name: "Memory",
        dimensions: [{name: "Hostname", value: process["hostname"]}],
        timestamp: timestamp,
        value: process["rss"],
        unit: "Kilobytes",
      }
    end
  end
end
```

  [metricdata]: https://docs.aws.amazon.com/sdk-for-ruby/v3/api/Aws/CloudWatch/Types/MetricDatum.html

#### Backward Compatibility

If you don't configure any metrics explicitly, ALL metrics will be published (default behavior). This ensures existing installations continue to work without any changes:

```ruby
# Without configuration - all metrics enabled (backward compatible)
Sidekiq::CloudWatchMetrics.enable!
```

#### Startup Logging

The gem will log the active metrics configuration on startup to help you verify your configuration:

```
INFO: Started Sidekiq CloudWatch Metrics Publisher
INFO: Metrics configuration: Enabled metrics: capacity, queue_latency, queue_size, utilization
```

Or if using defaults:

```
INFO: Started Sidekiq CloudWatch Metrics Publisher  
INFO: Metrics configuration: All metrics enabled (default)
```

### Additional Options

By default this assumes you're running on an EC2 instance with an instance role
that can publish CloudWatch metrics, or that you've supplied AWS credentials
through environment variables that aws-sdk expects. You can also explicitly
supply an [aws-sdk CloudWatch Client instance][cwclient]:

```ruby
Sidekiq::CloudWatchMetrics.enable!(client: Aws::CloudWatch::Client.new)
```

  [cwclient]: https://docs.aws.amazon.com/sdk-for-ruby/v3/api/Aws/CloudWatch/Client.html

The default namespace for metrics is "Sidekiq". You can configure this with the `namespace` option:

```ruby
Sidekiq::CloudWatchMetrics.enable!(namespace: "Sidekiq-Staging")
```

Metrics are published every 60 seconds by default. You can adjust this with the `interval` option:

```ruby
Sidekiq::CloudWatchMetrics.enable!(interval: 30)
```

Additional dimensions can be added to every published metric with the `additional_dimensions` option:

```ruby
Sidekiq::CloudWatchMetrics.enable!(additional_dimensions: {"Environment" => "staging"})
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`.

### Releasing

Bump the version in `sidekiq-cloudwatchmetrics.gemspec` and land the change on `main`.
After CI passes, run [Release gem](https://github.com/sj26/sidekiq-cloudwatchmetrics/actions/workflows/release.yml) on `main`.
The workflow creates the `v<version>` tag, publishes to RubyGems, then creates a GitHub release with generated notes and the same `.gem` file attached.

The workflow uses [RubyGems Trusted Publishing](https://guides.rubygems.org/trusted-publishing/).
Register `sj26/sidekiq-cloudwatchmetrics` with workflow filename `release.yml` and environment `release` on RubyGems.
Restrict the matching GitHub environment to the `main` branch. No RubyGems API key is needed.

If the gem is on RubyGems but the GitHub release step fails, download the published `.gem` from RubyGems and attach it to a GitHub release for the existing tag instead of publishing the gem again.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/sj26/sidekiq-cloudwatchmetrics.

## License

The gem is available as open source under the terms of the [MIT License](http://opensource.org/licenses/MIT).

