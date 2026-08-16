# frozen_string_literal: true

require 'test_helper'
require_relative 'ftp_server'

class FtpsyncIntegrationTest < Minitest::Test
  def self.server
    @server ||= FtpServer.new.tap(&:start)
  end

  Minitest.after_run do
    @server&.stop
  end

  def setup
    skip 'Docker is not available' unless FtpServer.available?
    server.reset
  end

  def test_pulls_a_directory_tree
    server.seed(
      'root/a.txt' => 'hello a',
      'root/sub/b.txt' => 'hello b'
    )

    Dir.mktmpdir do |local|
      sync.pull_dir('root', local)

      assert_equal 'hello a', File.read(File.join(local, 'a.txt'))
      assert_equal 'hello b', File.read(File.join(local, 'sub', 'b.txt'))
    end
  end

  def test_preserves_binary_file_contents
    payload = Random.bytes(1_048_576)
    server.seed('root/blob.bin' => payload)

    Dir.mktmpdir do |local|
      sync.pull_dir('root', local)

      assert_equal payload, File.binread(File.join(local, 'blob.bin'))
    end
  end

  def test_creates_missing_local_directories
    server.seed('root/a.txt' => 'hello')

    Dir.mktmpdir do |base|
      local = File.join(base, 'nested', 'deep')

      sync.pull_dir('root', local)

      assert File.directory?(local)
      assert_equal 'hello', File.read(File.join(local, 'a.txt'))
    end
  end

  def test_invokes_block_for_each_downloaded_file
    server.seed('root/a.txt' => 'one', 'root/b.txt' => 'two')

    Dir.mktmpdir do |local|
      downloaded = []
      sync.pull_dir('root', local) { |path| downloaded << path }

      assert_equal [File.join(local, 'a.txt'), File.join(local, 'b.txt')],
                   downloaded.sort
    end
  end

  def test_since_skips_unchanged_files
    server.seed('root/a.txt' => 'v1')

    Dir.mktmpdir do |local|
      sync.pull_dir('root', local, since: true)

      downloaded = []
      sync.pull_dir('root', local, since: true) { |path| downloaded << path }

      assert_empty downloaded
      assert_equal 'v1', File.read(File.join(local, 'a.txt'))
    end
  end

  def test_since_refetches_changed_files
    server.seed('root/a.txt' => 'version one')

    Dir.mktmpdir do |local|
      sync.pull_dir('root', local, since: true)
      server.seed('root/a.txt' => 'version two, longer')

      downloaded = []
      sync.pull_dir('root', local, since: true) { |path| downloaded << path }

      assert_equal [File.join(local, 'a.txt')], downloaded
      assert_equal 'version two, longer', File.read(File.join(local, 'a.txt'))
    end
  end

  private

  def server
    self.class.server
  end

  def sync
    FtpSync::Simple.new(FtpServer::HOST, FtpServer::USER, FtpServer::PASS,
                        passive: true, port: FtpServer::FTP_PORT)
  end
end
