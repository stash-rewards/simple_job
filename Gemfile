# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

group :rake do
  gem 'simple_gem', require: 'tasks/simple_gem'
end

group :test do
  gem 'rspec', '~> 3.7'

  # The VCR cassettes were recorded against SQS's legacy Query/XML protocol
  # (lockfile era: aws-sdk-sqs 1.35). aws-sdk-sqs >= 1.57 switched SQS to the
  # AWS JSON protocol and cannot play them back (Aws::Json::ParseError on the
  # recorded XML bodies). Test-only pin; the gemspec's runtime '~> 1' stands.
  gem 'aws-sdk-sqs', '< 1.57'

  gem 'byebug'
  gem 'rubocop'
  gem 'simplecov'
  gem 'vcr'
  gem 'webmock'

  %w[activemodel activesupport].each do |rails_gem|
    gem rails_gem, ENV.fetch('TEST_RAILS', '~> 6.1.0')
  end
end
