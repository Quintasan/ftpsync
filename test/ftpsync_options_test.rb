# frozen_string_literal: true

require 'support/sync_test_case'

class FtpsyncOptionsTest < SyncTestCase
  def test_uses_passive_mode_with_timeouts_by_default
    with_local_dir do |base|
      with_ftp('root' => []) do |ftp|
        sync.pull_dir('root', base)

        assert_equal({ passive: true, ssl: false, implicit_ftps: false,
                       open_timeout: 30, read_timeout: 60 },
                     ftp.new_args.last[1])
      end
    end
  end

  def test_passes_tls_and_timeout_options_to_net_ftp
    with_local_dir do |base|
      with_ftp('root' => []) do |ftp|
        options = { ssl: true, open_timeout: 5, read_timeout: 7, passive: false }
        FtpSync::Simple.new('ftp.example.com', 'user', 'pass', options).pull_dir('root', base)

        assert_equal({ passive: false, ssl: true, implicit_ftps: false, open_timeout: 5, read_timeout: 7 },
                     ftp.new_args.last[1])
      end
    end
  end

  def test_implicit_ftps_enables_tls
    with_local_dir do |base|
      with_ftp('root' => []) do |ftp|
        options = { implicit_ftps: true }
        FtpSync::Simple.new('ftp.example.com', 'user', 'pass', options).pull_dir('root', base)

        options = ftp.new_args.last[1]

        assert options[:ssl]
        assert options[:implicit_ftps]
      end
    end
  end

  def test_ssl_accepts_openssl_options
    with_local_dir do |base|
      with_ftp('root' => []) do |ftp|
        options = { ssl: { verify_mode: 0 } }
        FtpSync::Simple.new('ftp.example.com', 'user', 'pass', options).pull_dir('root', base)

        assert_equal({ verify_mode: 0 }, ftp.new_args.last[1][:ssl])
      end
    end
  end

  def test_verbose_logs_connecting_and_closing
    with_local_dir do |base|
      with_ftp('root' => []) do
        _out, err = capture_io do
          options = { verbose: true }
          FtpSync::Simple.new('ftp.example.com', 'user', 'pass', options).pull_dir('root', base)
        end

        assert_match(/Connecting to ftp\.example\.com:21/, err)
        assert_match(/Closed connection to ftp\.example\.com:21/, err)
      end
    end
  end

  def test_verbose_logs_errors_that_skip_errors_swallows
    with_local_dir do |base|
      with_ftp('root' => [file_entry('a.txt')]) do |ftp|
        ftp.fail_gets['root/a.txt'] = nil

        _out, err = capture_io do
          options = { verbose: true }
          simple = FtpSync::Simple.new('ftp.example.com', 'user', 'pass', options)
          simple.pull_dir('root', base, skip_errors: true)
        end

        assert_match(%r{Error while processing root/a\.txt}, err)
      end
    end
  end

  # The endpoint in the log is the one that was connected, not whatever the
  # accessors happen to say later.
  def test_logs_the_endpoint_that_was_connected
    with_ftp('root' => []) do
      simple = FtpSync::Simple.new('ftp.example.com', 'user', 'pass', verbose: true)

      _out, err = capture_io do
        simple.connect!
        simple.server = 'other.example.com'
        simple.close!
      end

      assert_match(/Closed connection to ftp\.example\.com:21/, err)
      refute_match(/other\.example\.com/, err)
    end
  end

  # log is the documented override hook: a subclass replaces it instead of
  # turning :verbose on and writing to stderr.
  def test_log_is_a_public_override_hook
    with_local_dir do |base|
      with_ftp('root' => [symlink_entry('link.txt')]) do
        simple = recording_sync
        simple.pull_dir('root', base)

        assert_logged(simple, 'root/link.txt', 'symbolic link')
      end
    end
  end

  def test_rejects_unknown_constructor_options
    error = assert_raises(ArgumentError) do
      FtpSync::Simple.new('ftp.example.com', 'user', 'pass', ssll: true)
    end

    assert_match(/:ssll/, error.message)
    assert_match(/constructor/, error.message)
  end

  def test_rejects_a_constructor_option_that_is_not_a_hash
    error = assert_raises(ArgumentError) { FtpSync::Simple.new('h', 'u', 'p', [:port]) }

    assert_match(/must be a Hash/, error.message)
  end

  def test_treats_nil_options_as_empty
    with_local_dir do |base|
      with_ftp('root' => []) do |ftp|
        simple = FtpSync::Simple.new('ftp.example.com', 'user', 'pass', nil)
        simple.pull_dir('root', base, nil)

        assert_equal 1, ftp.connect_count
      end
    end
  end

  # Options are validated before anything is connected, so a typo cannot be
  # discovered halfway through a transfer.
  def test_rejects_unknown_sync_options_before_connecting
    with_local_dir do |base|
      with_ftp('root' => []) do |ftp|
        error = assert_raises(ArgumentError) { sync.pull_dir('root', base, protct_local: true) }

        assert_match(/:protct_local/, error.message)
        assert_equal 0, ftp.connect_count
      end
    end
  end

  def test_rejects_unknown_sync_options_when_pushing
    with_local_dir do |base|
      write_files(base, 'a.txt' => 'one')

      with_ftp do |ftp|
        error = assert_raises(ArgumentError) { sync.push_dir(base, 'root', atomic_uploads: false) }

        assert_match(/:atomic_uploads/, error.message)
        assert_equal 0, ftp.connect_count
      end
    end
  end

  # :protect_local is a pull option. Ignoring it on push would hide a misplaced
  # option exactly the way an unknown key used to be hidden.
  def test_rejects_the_pull_only_option_when_pushing
    with_local_dir do |base|
      write_files(base, 'a.txt' => 'one')

      with_ftp do |ftp|
        error = assert_raises(ArgumentError) { sync.push_dir(base, 'root', protect_local: true) }

        assert_match(/:protect_local/, error.message)
        assert_equal 0, ftp.connect_count
      end
    end
  end

  # An empty remote path is the login directory, as in 0.1.0; only non-strings
  # are rejected.
  def test_rejects_a_remote_path_that_is_not_a_string
    with_local_dir do |base|
      [nil, :root].each do |remote_path|
        error = assert_raises(ArgumentError) { sync.pull_dir(remote_path, base) }

        assert_match(/remote path must be a String/, error.message)
      end
    end
  end

  def test_rejects_a_non_numeric_mtime_tolerance
    ['60', nil, -1].each do |tolerance|
      error = assert_raises(ArgumentError) do
        FtpSync::Simple.new('ftp.example.com', 'user', 'pass', mtime_tolerance: tolerance)
      end

      assert_match(/mtime_tolerance/, error.message)
      assert_match(/non-negative Numeric, got #{Regexp.escape(tolerance.inspect)}/, error.message)
    end
  end

  def test_zero_tolerance_uploads_a_file_that_is_any_amount_newer
    [0, 0.0].each do |tolerance|
      with_local_dir do |base|
        remote_time = Time.now - 600
        local_path = write_file(base, 'a.txt', 'data')
        set_mtime(local_path, remote_time + 30)

        with_ftp('root' => [file_entry('a.txt', mtime: remote_time, filesize: 4)]) do |ftp|
          ftp.fail_mdtms['root/a.txt'] = '502 MDTM not understood'
          sync = FtpSync::Simple.new('ftp.example.com', 'user', 'pass', mtime_tolerance: tolerance)
          sync.push_dir(base, 'root', since: true)

          assert_equal ['root/a.txt'], ftp.uploaded.map(&:last)
        end
      end
    end
  end

  def test_accepts_a_fractional_mtime_tolerance
    with_local_dir do |base|
      remote_time = Time.now - 600
      local_path = write_file(base, 'a.txt', 'data')
      set_mtime(local_path, remote_time + 30)

      with_ftp('root' => [file_entry('a.txt', mtime: remote_time, filesize: 4)]) do |ftp|
        ftp.fail_mdtms['root/a.txt'] = '502 MDTM not understood'
        sync = FtpSync::Simple.new('ftp.example.com', 'user', 'pass', mtime_tolerance: 30.5)
        sync.push_dir(base, 'root', since: true)

        assert_empty ftp.uploaded
      end
    end
  end

  def test_rejects_a_local_path_that_is_not_a_non_empty_string
    error = assert_raises(ArgumentError) { sync.push_dir('', 'root') }

    assert_match(/local path/, error.message)
    assert_match(/"/, error.message)
  end

  def test_keeps_the_missing_local_directory_error_for_push
    with_local_dir do |base|
      error = assert_raises(ArgumentError) { sync.push_dir(File.join(base, 'nope'), 'root') }

      assert_match(/is not a directory/, error.message)
    end
  end
end
