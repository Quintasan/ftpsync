# frozen_string_literal: true

require 'support/sync_test_case'

class FtpsyncPushSinceTest < SyncTestCase
  def test_since_skips_files_that_were_already_uploaded
    with_local_dir do |base|
      local_path = write_file(base, 'a.txt', 'data')
      set_mtime(local_path, Time.now - 3600)

      with_ftp do
        sync.push_dir(base, 'root')

        uploaded = []
        sync.push_dir(base, 'root', since: true) { |remote| uploaded << remote }

        assert_empty uploaded
      end
    end
  end

  def test_since_uploads_files_modified_after_the_last_upload
    with_local_dir do |base|
      local_path = write_file(base, 'a.txt', 'data')

      with_ftp do
        sync.push_dir(base, 'root')
        set_mtime(local_path, Time.now + 300)

        uploaded = []
        sync.push_dir(base, 'root', since: true) { |remote| uploaded << remote }

        assert_equal ['root/a.txt'], uploaded
      end
    end
  end

  def test_since_does_not_overwrite_a_newer_remote_file
    with_local_dir do |base|
      write_file(base, 'a.txt', 'data')

      with_ftp('root' => [file_entry('a.txt', mtime: Time.now + 300, filesize: 4)]) do
        uploaded = []
        sync.push_dir(base, 'root', since: true) { |remote| uploaded << remote }

        assert_empty uploaded
      end
    end
  end

  # LIST is a wall clock reading that net-ftp-list interprets as UTC, so on a
  # server ahead of UTC the LIST timestamp runs ahead of the real one. MDTM is
  # timezone independent and must be what decides this.
  def test_since_uses_mdtm_so_a_shifted_server_clock_does_not_hide_edits
    with_local_dir do |base|
      uploaded_at = Time.now - 3600
      local_path = write_file(base, 'a.txt', 'data')
      set_mtime(local_path, uploaded_at + 1800)

      with_shifted_ftp(7200, 'root' => [file_entry('a.txt', mtime: uploaded_at, filesize: 4)]) do |ftp|
        uploaded = []
        sync.push_dir(base, 'root', since: true) { |remote| uploaded << remote }

        assert_equal ['root/a.txt'], uploaded
        assert_equal ['root/a.txt'], ftp.mdtm_calls
      end
    end
  end

  # An unsupported MDTM is probed once per connection, not once per file, and
  # the LIST timestamp is used for the decision.
  def test_since_falls_back_to_the_list_timestamp_without_mdtm
    with_local_dir do |base|
      write_files(base, 'a.txt' => 'data', 'b.txt' => 'data')

      with_ftp('root' => [file_entry('a.txt', mtime: Time.now + 100, filesize: 4),
                          file_entry('b.txt', mtime: Time.now + 100, filesize: 4)]) do |ftp|
        ftp.fail_mdtms['root/a.txt'] = '502 MDTM not understood'
        ftp.fail_mdtms['root/b.txt'] = '502 MDTM not understood'

        uploaded = []
        sync.push_dir(base, 'root', since: true) { |remote| uploaded << remote }

        assert_empty uploaded
        assert_equal ['root/a.txt'], ftp.mdtm_calls
      end
    end
  end

  def test_a_per_file_mdtm_error_does_not_disable_mdtm
    with_local_dir do |base|
      write_files(base, 'a.txt' => 'data', 'b.txt' => 'data')

      with_ftp('root' => [file_entry('a.txt', mtime: Time.now + 100, filesize: 4),
                          file_entry('b.txt', mtime: Time.now + 100, filesize: 4)]) do |ftp|
        ftp.fail_mdtms['root/a.txt'] = '550 root/a.txt: No such file or directory'

        uploaded = []
        sync.push_dir(base, 'root', since: true) { |remote| uploaded << remote }

        assert_empty uploaded
        assert_equal %w[root/a.txt root/b.txt], ftp.mdtm_calls
      end
    end
  end

  def test_since_ignores_a_malformed_mdtm_time
    with_local_dir do |base|
      local_path = write_file(base, 'a.txt', 'data')
      set_mtime(local_path, Time.now - 3600)

      with_ftp('root' => [file_entry('a.txt', mtime: Time.now + 100, filesize: 4)]) do |ftp|
        ftp.mdtm_replies['root/a.txt'] = '20261301000000' # month 13

        uploaded = []
        sync.push_dir(base, 'root', since: true) { |remote| uploaded << remote }

        assert_empty uploaded
        assert_equal ['root/a.txt'], ftp.mdtm_calls
      end
    end
  end

  # A downgrade applies to one connection; a later sync probes again.
  def test_mdtm_is_probed_again_after_reconnecting
    with_local_dir do |base|
      write_file(base, 'a.txt', 'data')

      with_ftp('root' => [file_entry('a.txt', mtime: Time.now + 100, filesize: 4)]) do |ftp|
        ftp.fail_mdtms['root/a.txt'] = '502 MDTM not understood'

        simple = sync
        simple.push_dir(base, 'root', since: true)
        simple.push_dir(base, 'root', since: true)

        assert_equal ['root/a.txt', 'root/a.txt'], ftp.mdtm_calls
      end
    end
  end

  def test_since_uploads_files_missing_remotely
    with_local_dir do |base|
      write_files(base, 'a.txt' => 'data')

      with_ftp('root' => []) do |ftp|
        sync.push_dir(base, 'root', since: true)

        assert_equal %w[root/a.txt], ftp.uploaded.map(&:last)
      end
    end
  end

  # A listing that could not be read is not an empty directory. Treating it as
  # one would upload every local file over possibly newer remote copies, which
  # is exactly what :since exists to prevent.
  def test_since_does_not_upload_when_the_remote_listing_fails
    with_local_dir do |base|
      write_file(base, 'a.txt', 'local')

      with_ftp('root' => [file_entry('a.txt', mtime: Time.now + 300, filesize: 5)]) do |ftp|
        ftp.contents['root/a.txt'] = 'newer'
        ftp.fail_lists << 'root'

        result = sync.push_dir(base, 'root', since: true, skip_errors: true)

        assert_equal [[], [1, 0], 'newer'],
                     [ftp.attempted_puts, [result.failed, result.transferred], ftp.contents['root/a.txt']]
      end
    end
  end

  def test_since_uploads_changed_files
    with_local_dir do |base|
      write_files(base, 'a.txt' => 'data')

      with_ftp do |ftp|
        sync.push_dir(base, 'root')
        write_files(base, 'a.txt' => 'data plus more')
        sync.push_dir(base, 'root', since: true)

        assert_equal 2, ftp.uploaded.size
        assert_equal 'data plus more', ftp.contents['root/a.txt']
      end
    end
  end

  # MDTM is UTC with second precision, so the comparison needs almost no
  # tolerance: a file a few seconds newer than the remote copy is an edit and
  # must be uploaded.
  def test_since_compares_an_mdtm_time_with_a_two_second_tolerance
    with_local_dir do |base|
      uploaded_at = Time.now - 600
      local_path = write_file(base, 'a.txt', 'data')

      with_ftp('root' => [file_entry('a.txt', mtime: uploaded_at, filesize: 4)]) do |ftp|
        set_mtime(local_path, uploaded_at + 1)
        sync.push_dir(base, 'root', since: true)

        assert_empty ftp.uploaded

        set_mtime(local_path, uploaded_at + 30)
        sync.push_dir(base, 'root', since: true)

        assert_equal ['root/a.txt'], ftp.uploaded.map(&:last)
      end
    end
  end

  # A server that cannot report MDTM leaves LIST's wall clock, which keeps the
  # historical minute of tolerance.
  def test_since_tolerates_a_local_file_slightly_newer_than_a_list_stamp
    with_local_dir do |base|
      remote_time = Time.now - 600
      local_path = write_file(base, 'a.txt', 'data')
      set_mtime(local_path, remote_time + 30)

      with_ftp('root' => [file_entry('a.txt', mtime: remote_time, filesize: 4)]) do |ftp|
        ftp.fail_mdtms['root/a.txt'] = '502 MDTM not understood'

        sync.push_dir(base, 'root', since: true)

        assert_empty ftp.uploaded
        assert_equal ['root/a.txt'], ftp.mdtm_calls
      end
    end
  end

  def test_mtime_tolerance_narrows_the_list_window
    with_local_dir do |base|
      remote_time = Time.now - 600
      local_path = write_file(base, 'a.txt', 'data')
      set_mtime(local_path, remote_time + 30)

      with_ftp('root' => [file_entry('a.txt', mtime: remote_time, filesize: 4)]) do |ftp|
        ftp.fail_mdtms['root/a.txt'] = '502 MDTM not understood'
        sync = FtpSync::Simple.new('ftp.example.com', 'user', 'pass', mtime_tolerance: 10)
        sync.push_dir(base, 'root', since: true)

        assert_equal ['root/a.txt'], ftp.uploaded.map(&:last)
      end
    end
  end

  def test_mtime_tolerance_defaults_to_sixty_seconds
    with_local_dir do |base|
      remote_time = Time.now - 600
      local_path = write_file(base, 'a.txt', 'data')
      set_mtime(local_path, remote_time + 90)

      with_ftp('root' => [file_entry('a.txt', mtime: remote_time, filesize: 4)]) do |ftp|
        ftp.fail_mdtms['root/a.txt'] = '502 MDTM not understood'

        sync.push_dir(base, 'root', since: true)

        assert_equal ['root/a.txt'], ftp.uploaded.map(&:last)
      end
    end
  end
end
