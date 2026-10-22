# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'rake/testtask'
require 'rubocop/rake_task'

Rake::TestTask.new(:test) do |t|
  t.libs << 'test'
  t.libs << 'lib'
  t.test_files = FileList['test/*_test.rb']
end

desc 'Run integration tests against a Dockerized FTP server'
Rake::TestTask.new(:'test:integration') do |t|
  t.libs << 'test'
  t.libs << 'lib'
  t.test_files = FileList['test/integration/**/*_test.rb']
end

RuboCop::RakeTask.new

# A missing gem must say why it is missing instead of raising a LoadError.
def require_type_checking_tools!
  missing = %w[rbs steep].reject { |name| Gem::Specification.find_all_by_name(name).any? }
  return if missing.empty?

  abort <<~MESSAGE
    #{missing.join(' and ')} not installed: type checking needs Ruby >= 3.3,
    where the Gemfile adds rbs and steep. Run `bundle install` on such a Ruby;
    CI runs the same checks in the "types" job on Ruby 4.0.
  MESSAGE
end

# Type checking. Both tasks stay out of `default` on purpose: `rake` is test +
# RuboCop, and the Steep gems are only installed on Ruby >= 3.3 (see the
# Gemfile), so the 3.0 job has nothing to load them with.
desc 'Type check lib/ against sig/ with Steep'
task :steep do
  require_type_checking_tools!
  ruby Gem.bin_path('steep', 'steep'), 'check'
end

desc 'Validate the RBS signatures in sig/'
task :rbs do
  require_type_checking_tools!
  ruby Gem.bin_path('rbs', 'rbs'), '-I', 'sig', 'validate'
end

task default: %i[test rubocop]
