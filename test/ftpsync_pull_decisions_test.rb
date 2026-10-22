# frozen_string_literal: true

require 'support/sync_test_case'

# What pull_dir decides to do with the entries a listing reports: what it
# transfers, what it refuses to touch and what it says about both.
class FtpsyncPullDecisionsTest < SyncTestCase
  # Entries that are neither files nor directories used to vanish without a
  # word; a skip the user cannot see is a hole in the local tree. Entries whose
  # type is *known* stay skips; see the unparseable-entry test below for the
  # type nobody could determine.
  def test_skips_and_logs_known_non_file_entries
    with_local_dir do |base|
      entries = [symlink_entry('link.txt'), device_entry('tty')]

      with_ftp('root' => entries + [file_entry('a.txt')]) do
        simple = recording_sync
        result = simple.pull_dir('root', base)

        assert_equal [1, 2], [result.transferred, result.skipped]
        assert_equal ['a.txt'], Dir.children(base)
        assert_equal ['Skipping root/link.txt: symbolic link',
                      'Skipping root/tty: device'],
                     simple.messages.grep(/\ASkipping /)
      end
    end
  end

  # A line no parser understood is not a skip: the entry may be a file, so the
  # run has to report that it could not read it instead of looking clean.
  def test_an_unparseable_listing_entry_is_a_reported_failure
    with_local_dir do |base|
      with_ftp('root' => [file_entry('a.txt'), unparseable_entry('garbage')]) do
        simple = recording_sync
        result = simple.pull_dir('root', base)

        assert_equal [1, 0, 1], [result.transferred, result.skipped, result.failed]
        assert_equal [['root/garbage', FtpSync::Simple::UNUSABLE_ENTRY]], result.errors
        assert_logged(simple, 'root/garbage', FtpSync::Simple::UNUSABLE_ENTRY)
      end
    end
  end

  # The local directory must not be created before the listing succeeded: a
  # typo in the remote path would otherwise leave an empty tree behind.
  def test_a_failed_remote_listing_does_not_leave_an_empty_local_tree
    with_local_dir do |base|
      target = File.join(base, 'typo')

      with_ftp('root' => []) do |ftp|
        ftp.fail_lists << 'typo'

        result = sync.pull_dir('typo', target, skip_errors: true)

        refute_path_exists target
        assert_equal 1, result.failed
        assert_equal 'typo', result.errors.first.first
      end
    end
  end

  def test_lists_the_login_directory_for_an_empty_remote_path
    with_local_dir do |base|
      with_ftp('' => [file_entry('a.txt')]) do |ftp|
        sync.pull_dir('', base)

        assert_equal ['a.txt'], ftp.downloaded.map(&:first)
        assert_equal remote_content('a.txt'), File.read(File.join(base, 'a.txt'))
      end
    end
  end

  def test_warns_before_overwriting_a_local_file_that_is_newer
    with_local_dir do |base|
      local = write_file(base, 'a.txt', 'mine')
      set_mtime(local, Time.now)

      with_ftp('root' => [file_entry('a.txt', mtime: Time.now - 600, filesize: 4)]) do
        simple = recording_sync
        result = simple.pull_dir('root', base)

        assert_equal 1, result.transferred
        assert_logged(simple, 'Overwriting', local)
        refute(simple.messages.any? { |message| message.start_with?("Skipping #{local}") })
      end
    end
  end

  def test_protect_local_keeps_a_local_file_that_is_newer
    with_local_dir do |base|
      local = write_file(base, 'a.txt', 'mine')
      set_mtime(local, Time.now)

      with_ftp('root' => [file_entry('a.txt', mtime: Time.now - 600, filesize: 4)]) do |ftp|
        simple = recording_sync
        result = simple.pull_dir('root', base, protect_local: true)

        assert_empty ftp.downloaded
        assert_equal ['mine', 1], [File.read(local), result.skipped]
        assert_logged(simple, 'Skipping', local, 'newer than the remote copy')
      end
    end
  end

  # A protected file is not overwritten, so saying that it is would be a lie.
  def test_says_only_that_it_skips_a_file_it_protects
    with_local_dir do |base|
      local = write_file(base, 'a.txt', 'mine')
      set_mtime(local, Time.now)

      with_ftp('root' => [file_entry('a.txt', mtime: Time.now - 600, filesize: 4)]) do
        simple = recording_sync
        simple.pull_dir('root', base, protect_local: true)

        logged = simple.messages.select { |message| message.end_with?('newer than the remote copy') }

        assert_equal ["Skipping #{local}: newer than the remote copy"], logged
      end
    end
  end

  def test_protecting_a_local_file_stays_silent_without_verbose
    with_local_dir do |base|
      local = write_file(base, 'a.txt', 'mine')
      set_mtime(local, Time.now)

      with_ftp('root' => [file_entry('a.txt', mtime: Time.now - 600, filesize: 4)]) do
        _out, err = capture_io { sync.pull_dir('root', base, protect_local: true) }

        assert_empty err
      end
    end
  end

  def test_warns_when_the_transferred_size_does_not_match_the_listing
    with_local_dir do |base|
      with_ftp({ 'root' => [file_entry('a.txt', filesize: 100)] },
               { 'root/a.txt' => 'short' }) do
        simple = recording_sync
        simple.pull_dir('root', base)

        assert_logged(simple, 'Size mismatch for root/a.txt', 'expected 100 bytes, received 5')
        assert_equal 'short', File.read(File.join(base, 'a.txt'))
      end
    end
  end

  def test_does_not_warn_when_the_transferred_size_matches_the_listing
    with_local_dir do |base|
      with_ftp({ 'root' => [file_entry('a.txt', filesize: 5)] },
               { 'root/a.txt' => 'short' }) do
        simple = recording_sync
        simple.pull_dir('root', base)

        refute(simple.messages.any? { |message| message.include?('Size mismatch') })
      end
    end
  end

  def test_downloads_ask_for_a_binary_transfer_explicitly
    with_local_dir do |base|
      with_ftp('root' => [file_entry('a.txt')]) do |ftp|
        sync.pull_dir('root', base)

        assert_empty ftp.get_calls
        assert_equal 1, ftp.downloaded.size
      end
    end
  end

  def test_a_sync_without_verbose_is_silent
    with_local_dir do |base|
      with_ftp('root' => [symlink_entry('link.txt'), file_entry('a.txt')]) do
        _out, err = capture_io { sync.pull_dir('root', base) }

        assert_empty err
      end
    end
  end
end
