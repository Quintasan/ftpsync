# frozen_string_literal: true

# Coverage is opt-in through `rake coverage`, which sets COVERAGE. The floor is
# part of that task: the integration suite loads the library only in part, and a
# developer running a single test file should not be told the whole library is
# untested.
if ENV['COVERAGE']
  require 'simplecov'

  SimpleCov.start do
    track_files 'lib/**/*.rb'
    add_filter '/test/'
    # The Gemfile takes its dependency on this gem from the gemspec, and
    # Bundler evaluates that gemspec before the tests start. version.rb is
    # therefore already loaded when coverage begins and Ruby records nothing
    # for it; its own test still runs, it is just not a file that can be timed.
    add_filter '/lib/ftpsync/version.rb'
    minimum_coverage 98
  end
end

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'ftpsync'

# Object#stub comes from minitest/mock. It must be required explicitly:
# minitest 6 drops it, and relying on it arriving with minitest/autorun would
# break this suite on upgrade.
require 'minitest/mock'
require 'minitest/autorun'
