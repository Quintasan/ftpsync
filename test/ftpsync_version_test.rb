# frozen_string_literal: true

require 'test_helper'
require 'ftpsync/version'

# FtpSync::VERSION is the one place the gemspec reads the version from, so the
# only way it can go wrong is by not being released: a version without a
# CHANGELOG entry, or an entry nobody bumped the constant for.
class FtpsyncVersionTest < Minitest::Test
  def test_the_version_is_semver
    assert_match(/\A\d+\.\d+\.\d+\z/, FtpSync::VERSION)
  end

  def test_the_newest_released_changelog_entry_is_the_current_version
    changelog = File.read(File.expand_path('../CHANGELOG.md', __dir__))

    assert_equal FtpSync::VERSION, changelog[/^## \[(\d+\.\d+\.\d+)\]/, 1]
  end
end
