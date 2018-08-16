# coding: utf-8
Gem::Specification.new do |spec|
  spec.name          = "sidekiq-cloudwatchmetrics"
  spec.version       = "1.0.0"
  spec.author        = "Samuel Cochran"
  spec.email         = "sj26@sj26.com"

  spec.summary       = %q{Publish Sidekiq metrics to AWS CloudWatch}
  spec.description   = <<~EOS
    Runs a thread inside your Sidekiq processes to report metrics to CloudWatch
    useful for autoscaling and keeping an eye on your queues.

    Optimised for Sidekiq Enterprise with leader election, but works everywhere!
  EOS
  spec.homepage      = "https://github.com/sj26/sidekiq-cloudwatchmetrics"
  spec.license       = "MIT"

  spec.files         = Dir["README.md", "LICENSE", "lib/**/*.rb"]

  spec.required_ruby_version = "~> 2.4"

  spec.add_runtime_dependency "sidekiq", "~> 5.0"
  spec.add_runtime_dependency "aws-sdk-cloudwatch", "~> 1.6"

  spec.add_development_dependency "bundler", "~> 1.16"
  spec.add_development_dependency "rake", "~> 10.0"
  spec.add_development_dependency "rspec", "~> 3.7"
  spec.add_development_dependency "timecop", "~> 0.9"
end
