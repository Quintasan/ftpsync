# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'ftpsync/version'

Gem::Specification.new do |spec|
  spec.name          = "ftpsync"
  spec.version       = FtpSync::VERSION
  spec.authors       = ["Michał Zając"]
  spec.email         = ["rubygems.org@quintasan.pl"]

  spec.summary       = %q{A simple library for synchronizing from/to FTP servers.}
  spec.homepage      = "https://github.com/Quintasan/ftpsync"
  spec.license       = "MIT"

  spec.files         = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "net-ftp-list", ">= 3.2.8"

  spec.add_development_dependency "bundler", "~> 1.10"
  spec.add_development_dependency "rake", "~> 10.0"
  spec.add_development_dependency "minitest"
end
