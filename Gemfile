# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

group :rake do
  gem 'simple_gem', require: 'tasks/simple_gem'
end

group :test do
  gem 'rspec', '~> 3.7'

  # The VCR cassettes were recorded (2021-01, see their User-Agent headers)
  # with aws-sdk-core 3.111 / aws-sdk-sqs 1.35 / aws-sdk-cloudwatch 1.47 and
  # played back through vcr 4.0 / webmock 3.1 - the committed lockfile's
  # last-green set. Newer service gems speak the AWS JSON protocol instead of
  # Query/XML, and a new core paired with old service gems returns broken
  # response objects, so the whole recorded-era set is pinned. Test-only pins;
  # the gemspec's runtime '~> 1' constraints stand.
  gem 'aws-sdk-cloudwatch', '~> 1.47.0'
  gem 'aws-sdk-core', '~> 3.111.0'
  gem 'aws-sdk-sqs', '~> 1.35.0'
  gem 'vcr', '~> 4.0.0'
  gem 'webmock', '~> 3.1.1'

  gem 'byebug'
  gem 'rubocop'
  gem 'simplecov'

  %w[activemodel activesupport].each do |rails_gem|
    gem rails_gem, ENV.fetch('TEST_RAILS', '~> 6.1.0')
  end
end
