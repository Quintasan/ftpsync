# frozen_string_literal: true

source 'https://rubygems.org'

# Specify your gem's dependencies in ftpsync.gemspec
gemspec

group :development, :test do
  # 6.x requires Ruby >= 3.2 and drops minitest/mock, which the test suite uses
  # through Object#stub, so 5.x is the ceiling while CI covers Ruby 3.0/3.1.
  gem 'minitest', '~> 5.0'
  gem 'rake', '~> 13.0'
  # Minor pins keep the lint job reproducible: `NewCops: enable` means a cop
  # added in a fresh 1.x release can fail a commit that changed nothing.
  gem 'rubocop', '~> 1.92.0'
  gem 'rubocop-minitest', '~> 0.41.0'
  gem 'rubocop-rake', '~> 0.7.1'

  # Type checking. Steep 2.x requires Ruby >= 3.3 (rbs 4.x does too), while every
  # entry of the CI matrix runs `bundle install`. Declaring these
  # unconditionally would make the Ruby 3.0-3.2 jobs unresolvable, and the gem
  # itself still supports Ruby >= 2.6, so they only exist where the tools can
  # run. `rake steep`/`rake rbs` explain the same thing when they are missing.
  if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('3.3')
    # Minor pins keep the types job reproducible, as with RuboCop above.
    gem 'rbs', '~> 4.2.0'
    gem 'steep', '~> 2.1.0'
  end
end
