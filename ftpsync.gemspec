# frozen_string_literal: true

require_relative 'lib/ftpsync/version'

Gem::Specification.new do |spec|
  spec.name = 'ftpsync'
  spec.version = FtpSync::VERSION
  spec.authors = ['Michał Zając']
  spec.email = ['rubygems.org@quintasan.pl']

  spec.summary = 'A simple library for synchronizing from/to FTP servers.'
  spec.description = 'Recursively pull from and push to FTP servers, with support ' \
                     'for incremental syncs, TLS and per-file callbacks.'
  spec.homepage = 'https://github.com/Quintasan/ftpsync'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 2.6.0'

  spec.metadata = {
    'bug_tracker_uri' => "#{spec.homepage}/issues",
    'changelog_uri' => "#{spec.homepage}/blob/master/CHANGELOG.md",
    'documentation_uri' => "#{spec.homepage}/blob/master/README.md",
    'homepage_uri' => spec.homepage,
    'source_code_uri' => spec.homepage,
    'rubygems_mfa_required' => 'true'
  }

  # Files that exist only to develop the gem. They are not part of the
  # library, so they must not reach the packaged artifact. `sig/` is API and
  # ships; the Steepfile is local tool configuration like .rubocop.yml.
  dev_only_paths = %r{\A(bin|test|spec|features|\.github|\.operator)/}
  dev_only_files = %w[.rubocop.yml Gemfile Steepfile].freeze

  # `git ls-files` is empty outside a git checkout (export tarball,
  # `git archive`, Docker build), and `gem build` would then happily package an
  # empty gem. Fall back to a glob so the library still ships in those builds.
  spec.files = Dir.chdir(__dir__) do
    files = `git ls-files -z 2>/dev/null`.split("\x0")
    files = Dir.glob('{lib/**/*,sig/**/*.rbs,*.gemspec,CHANGELOG.md,LICENSE.txt,README.md}') if files.empty?
    files.reject do |file|
      file.match?(dev_only_paths) || dev_only_files.include?(file) || !File.file?(file)
    end
  end
  spec.require_paths = ['lib']

  spec.add_dependency 'net-ftp', '>= 0.3.9'
  spec.add_dependency 'net-ftp-list', '>= 3.2.8'
end
