# frozen_string_literal: true

require_relative 'lib/ftpsync/version'

Gem::Specification.new do |spec|
  spec.name = 'ftpsync'
  spec.version = FtpSync::VERSION
  spec.authors = ['Michał Zając']
  spec.email = ['rubygems.org@quintasan.pl']

  spec.summary = 'A simple library for synchronizing from/to FTP servers.'
  spec.description = 'Recursively pull directory trees from FTP servers, with support ' \
                     'for incremental syncs and per-file callbacks.'
  spec.homepage = 'https://github.com/Quintasan/ftpsync'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 2.6.0'

  spec.metadata = {
    'source_code_uri' => spec.homepage,
    'rubygems_mfa_required' => 'true'
  }

  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      f.match?(%r{^(test|spec|features)/|^\.github/}) || !File.file?(f)
    end
  end
  spec.require_paths = ['lib']

  spec.add_dependency 'net-ftp'
  spec.add_dependency 'net-ftp-list', '>= 3.2.8'
end
