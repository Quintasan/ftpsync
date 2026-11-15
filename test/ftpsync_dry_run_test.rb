# frozen_string_literal: true

require 'support/sync_test_case'

# :dry_run reads both sides and reports what a real run would have changed,
# without transferring or deleting anything. Directory creation is not
# reported: a real run only makes a directory to hold a file it is about to
# transfer, which the dry run already counts.
class FtpsyncDryRunTest < SyncTestCase
  def test_pull_reports_a_download_it_does_not_make
    with_local_dir do |base|
      with_ftp({ 'root' => [file_entry('a.txt')] }) do |ftp|
        simple = recording_sync
        result = simple.pull_dir('root', base, dry_run: true)

        assert_equal [1, []], [result.transferred, Dir.children(base)]
        assert_empty ftp.downloaded
      end
    end
  end

  def test_pull_says_what_it_would_download
    with_local_dir do |base|
      with_ftp({ 'root' => [file_entry('a.txt')] }) do
        simple = recording_sync
        simple.pull_dir('root', base, dry_run: true)

        assert_logged(simple, 'Would download root/a.txt =>', File.join(base, 'a.txt'))
        refute_path_exists File.join(base, 'a.txt')
      end
    end
  end

  def test_pull_counts_a_deletion_it_does_not_make
    with_local_dir do |base|
      write_file(base, 'stale.txt', 'old')

      with_ftp('root' => []) do
        simple = recording_sync
        result = simple.pull_dir('root', base, prune: true, dry_run: true)

        assert_equal [1, ['stale.txt']], [result.deleted, Dir.children(base)]
        assert_logged(simple, 'Would delete', 'stale.txt')
      end
    end
  end

  def test_push_reports_an_upload_it_does_not_make
    with_local_dir do |base|
      write_file(base, 'a.txt', 'data')

      with_ftp('root' => []) do |ftp|
        simple = recording_sync
        result = simple.push_dir(base, 'root', dry_run: true)

        assert_equal [1, []], [result.transferred, ftp.uploaded]
        assert_logged(simple, 'Would upload', 'root/a.txt')
      end
    end
  end

  def test_push_creates_no_remote_directory
    with_local_dir do |base|
      write_file(base, 'sub/a.txt', 'data')

      with_ftp({ 'root' => [dir_entry('sub')] }) do |ftp|
        sync.push_dir(base, 'root', dry_run: true)

        assert_empty ftp.created_dirs
      end
    end
  end

  def test_push_counts_a_deletion_it_does_not_make
    with_local_dir do |base|
      with_ftp({ 'root' => [file_entry('stale.txt')] }, 'root/stale.txt' => 'old') do |ftp|
        simple = recording_sync
        result = simple.push_dir(base, 'root', prune: true, dry_run: true)

        assert_equal [1, 'old'], [result.deleted, ftp.contents['root/stale.txt']]
        assert_logged(simple, 'Would delete', 'root/stale.txt')
      end
    end
  end

  def test_a_dry_run_fires_no_callback
    with_local_dir do |base|
      with_ftp({ 'root' => [file_entry('a.txt')] }) do
        seen = []
        sync.pull_dir('root', base, dry_run: true) { |path| seen << path }

        assert_empty seen
      end
    end
  end
end
