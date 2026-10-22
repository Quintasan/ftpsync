# frozen_string_literal: true

require 'fileutils'
require 'test_helper'
require 'support/fake_ftp'

# Shared helpers for the unit tests: temporary local directories, a FakeFtp
# wired into Net::FTP, and fixture builders.
class SyncTestCase < Minitest::Test
  # FtpSync::Simple with the public log hook redirected into an array, so a
  # test can assert on diagnostics without turning on :verbose.
  class RecordingSync < FtpSync::Simple
    attr_reader :messages

    def initialize(*args)
      super
      @messages = []
    end

    def log(message)
      @messages << message
    end
  end

  private

  def sync
    FtpSync::Simple.new('ftp.example.com', 'user', 'pass', verbose: false)
  end

  def recording_sync
    RecordingSync.new('ftp.example.com', 'user', 'pass')
  end

  def with_local_dir(&block)
    Dir.mktmpdir(&block)
  end

  def with_ftp(listings = {}, contents = {}, server_offset = 0)
    ftp = FakeFtp.new(listings, contents: contents, server_offset: server_offset)
    Net::FTP.stub(:new, lambda { |*args|
      ftp.record_new_args(args)
      ftp
    }) do
      Net::FTP::List.stub(:parse, ->(line) { ftp.entry_for(line) }) do
        yield ftp
      end
    end
  end

  def dir_entry(name)
    FakeFtp::Entry.new(name, :dir, Time.now, 0)
  end

  def file_entry(name, mtime: Time.now, filesize: 0)
    FakeFtp::Entry.new(name, :file, mtime, filesize)
  end

  def symlink_entry(name, mtime: Time.now, filesize: 0)
    FakeFtp::Entry.new(name, :symlink, mtime, filesize)
  end

  def device_entry(name, mtime: Time.now, filesize: 0)
    FakeFtp::Entry.new(name, :device, mtime, filesize)
  end

  # A LIST line that none of the parsers understood: the real gem emits an
  # entry with no type at all.
  def unparseable_entry(name)
    FakeFtp::Entry.new(name, nil, Time.now, 0)
  end

  def write_file(base, path, content)
    full = File.join(base, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
    full
  end

  def write_files(base, files)
    files.each { |path, content| write_file(base, path, content) }
  end

  def set_mtime(path, time)
    File.utime(time, time, path)
  end

  def remote_content(remote)
    "content of #{remote}"
  end

  # Remote path a transfer in progress uses, for the assertions that must see
  # the side file rather than the destination.
  def partial_path(remote)
    "#{remote}#{FtpSync::Simple::PART_SUFFIX}"
  end

  # Asserts that one captured log line contains all the fragments given.
  def assert_logged(simple, *fragments)
    matched = simple.messages.any? do |message|
      fragments.all? { |fragment| message.include?(fragment) }
    end

    assert matched, "expected a log line containing #{fragments.inspect}, got:\n#{simple.messages.join("\n")}"
  end

  # A server whose LIST clock leads UTC by +server_offset+, as one running in
  # a non-UTC timezone does.
  def with_shifted_ftp(server_offset, listings = {}, contents = {}, &block)
    with_ftp(listings, contents, server_offset, &block)
  end
end
