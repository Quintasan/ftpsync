# frozen_string_literal: true

require 'support/sync_test_case'

# The preferred listing source: MLSD gives typed entries and UTC modify stamps,
# so it replaces LIST wherever a server has it. The integration server (ftpd)
# speaks LIST only, so the fallback and this whole file live in the unit suite.
class FtpsyncMlsxTest < SyncTestCase
  def test_an_mlsx_directory_is_pulled_without_asking_for_list
    with_local_dir do |base|
      with_ftp({ 'root' => [file_entry('a.txt', filesize: 4)] }, 'root/a.txt' => 'data') do |ftp|
        ftp.mlsx = true
        sync.pull_dir('root', base)

        assert_equal [['root'], []], [ftp.mlsd_calls, ftp.list_calls]
        assert_equal 'data', File.read(File.join(base, 'a.txt'))
      end
    end
  end

  def test_the_mlsx_verdict_is_remembered_for_the_connection
    with_local_dir do |base|
      listings = { 'root' => [dir_entry('sub')], 'root/sub' => [file_entry('b.txt')] }

      with_ftp(listings, 'root/sub/b.txt' => 'data') do |ftp|
        simple = recording_sync
        simple.pull_dir('root', base)

        # One probe, then every listing of the connection uses LIST.
        assert_equal [['root'], %w[root root/sub]], [ftp.mlsd_calls, ftp.list_calls]
        assert_equal 1, simple.messages.grep(/does not implement MLSD/).size
        assert_equal 'data', File.read(File.join(base, 'sub', 'b.txt'))
      end
    end
  end

  def test_a_real_mlsx_failure_is_reported_and_not_retried_with_list
    with_local_dir do |base|
      with_ftp('root' => [file_entry('a.txt')]) do |ftp|
        ftp.mlsx = true
        ftp.fail_mlsd['root'] = '550 Permission denied'

        result = sync.pull_dir('root', base, skip_errors: true)

        assert_equal [[], [1, 0]], [ftp.list_calls, [result.failed, result.transferred]]
        assert_equal [['root', '550 Permission denied']], result.errors
      end
    end
  end

  # The type fact alone decides: a server that names its pseudo entries
  # differently still must not have them transferred.
  def test_cdir_and_pdir_entries_are_dropped_by_type
    facts = { 'type' => 'cdir' }

    assert_nil FtpSync::Simple::Entry.from_mlsx(Net::FTP::MLSxEntry.new(facts, 'anything'))
    assert_nil FtpSync::Simple::Entry.from_mlsx(Net::FTP::MLSxEntry.new({ 'type' => 'pdir' }, 'anything'))
  end

  def test_the_cdir_and_pdir_pseudo_entries_are_ignored
    with_local_dir do |base|
      with_ftp('root' => [file_entry('a.txt')]) do |ftp|
        ftp.mlsx = true
        result = sync.pull_dir('root', base)

        assert_equal [1, 0, 0], [result.transferred, result.skipped, result.failed]
        assert_equal ['a.txt'], Dir.children(base)
      end
    end
  end

  # An MLSx type nobody knows leaves the entry unreadable, which is a failure
  # rather than a skip.
  def test_an_unknown_mlsx_type_is_a_reported_failure
    with_local_dir do |base|
      with_ftp('root' => [file_entry('a.txt'), file_entry('b.txt')]) do |ftp|
        ftp.mlsx = true
        ftp.mlsx_facts['b.txt'] = { 'type' => 'banana' }

        result = sync.pull_dir('root', base)

        assert_equal [1, 0, 1], [result.transferred, result.skipped, result.failed]
        assert_equal [['root/b.txt', FtpSync::Simple::UNUSABLE_ENTRY]], result.errors
        assert_equal ['a.txt'], Dir.children(base)
      end
    end
  end

  # The MLSx modify stamp is stored on the file exactly as reported, so the next
  # :since run recognises its own work.
  def test_pull_stores_the_mlsx_time_so_the_next_since_run_skips
    with_local_dir do |base|
      remote_time = Time.utc(2026, 1, 2, 3, 4, 5)
      entries = [file_entry('a.txt', mtime: remote_time, filesize: 4)]

      with_ftp({ 'root' => entries }, 'root/a.txt' => 'data') do |ftp|
        ftp.mlsx = true
        simple = sync
        simple.pull_dir('root', base)
        simple.pull_dir('root', base, since: true)

        assert_equal remote_time.to_i, File.mtime(File.join(base, 'a.txt')).to_i
        assert_equal 1, ftp.downloaded.size
      end
    end
  end

  # The local file is the same size and newer than the remote stamp would be,
  # so only the missing time can keep it from counting as current.
  def test_since_downloads_an_entry_without_a_usable_mtime
    with_local_dir do |base|
      local = write_file(base, 'a.txt', 'data')
      set_mtime(local, Time.now)
      entries = [file_entry('a.txt', mtime: Time.now - 600, filesize: 4)]

      with_ftp({ 'root' => entries }, 'root/a.txt' => 'new!') do |ftp|
        ftp.mlsx = true
        ftp.mlsx_facts['a.txt'] = { 'type' => 'file', 'size' => 4, 'modify' => nil }

        result = sync.pull_dir('root', base, since: true)

        assert_equal 1, result.transferred
        assert_equal 'new!', File.read(local)
      end
    end
  end

  def test_protect_local_keeps_the_local_file_when_the_remote_time_is_missing
    with_local_dir do |base|
      local = write_file(base, 'a.txt', 'mine')
      entries = [file_entry('a.txt', mtime: Time.now - 600, filesize: 4)]

      with_ftp({ 'root' => entries }, 'root/a.txt' => 'new!') do |ftp|
        ftp.mlsx = true
        ftp.mlsx_facts['a.txt'] = { 'type' => 'file', 'size' => 4, 'modify' => nil }

        result = sync.pull_dir('root', base, protect_local: true)

        assert_equal ['mine', 1], [File.read(local), result.skipped]
      end
    end
  end

  # The entry's own provenance decides the tolerance, even when MDTM has to be
  # ruled out first: an MLSx stamp is UTC with second precision, so a file 30
  # seconds newer is an edit, not clock drift.
  def test_push_since_treats_an_mlsx_time_as_second_precision
    with_local_dir do |base|
      remote_time = Time.now - 600
      local_path = write_file(base, 'a.txt', 'data')
      set_mtime(local_path, remote_time + 30)
      entries = [file_entry('a.txt', mtime: remote_time, filesize: 4)]

      with_ftp('root' => entries) do |ftp|
        ftp.mlsx = true
        ftp.fail_mdtms['root/a.txt'] = '502 MDTM not understood'
        sync.push_dir(base, 'root', since: true)

        assert_equal ['root/a.txt'], ftp.uploaded.map(&:last)
      end
    end
  end

  # A listing that could not be read whole cannot prove freshness, so :since
  # must not upload over it.
  def test_push_since_does_not_upload_from_a_partial_mlsx_listing
    with_local_dir do |base|
      write_file(base, 'a.txt', 'local')
      entries = [file_entry('a.txt', mtime: Time.now + 300, filesize: 5)]

      with_ftp({ 'root' => entries }, 'root/a.txt' => 'newer') do |ftp|
        ftp.mlsx = true
        ftp.mlsx_facts['a.txt'] = { 'type' => 'banana' }

        result = sync.push_dir(base, 'root', since: true, skip_errors: true)

        assert_equal [[], 1], [ftp.attempted_puts, result.failed]
        assert_equal 'newer', ftp.contents['root/a.txt']
      end
    end
  end
end
