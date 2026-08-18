# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

group :rake do
  gem 'simple_gem', require: 'tasks/simple_gem'
end

group :test do
  gem 'rspec', '~> 3.7'

  # The VCR cassettes were recorded against the legacy Query/XML protocol
  # (lockfile era: aws-sdk-sqs 1.35 / aws-sdk-cloudwatch 1.47). Newer service
  # gems switched to the AWS JSON protocol and cannot play the recorded XML
  # back (Aws::Json::ParseError; the CloudWatch one is swallowed by poll's
  # rescue and shows up as an empty result). Test-only pins; the gemspec's
  # runtime '~> 1' constraints stand.
  gem 'aws-sdk-sqs', '< 1.57'
  gem 'aws-sdk-cloudwatch', '~> 1.47.0'

  gem 'byebug'
  gem 'rubocop'
  gem 'simplecov'
  gem 'vcr'
  gem 'webmock'

  %w[activemodel activesupport].each do |rails_gem|
    gem rails_gem, ENV.fetch('TEST_RAILS', '~> 6.1.0')
  end
end
