# frozen_string_literal: true

require 'support/sync_test_case'

# :prune deletes what the source no longer has, in both directions. It is opt-in
# and only ever deletes from a listing that was read and interpreted whole.
class FtpsyncPruneTest < SyncTestCase
  def test_prune_deletes_a_local_file_the_remote_does_not_have
    with_local_dir do |base|
      write_file(base, 'stale.txt', 'old')
      write_file(base, 'a.txt', 'old')

      with_ftp({ 'root' => [file_entry('a.txt')] }, 'root/a.txt' => 'new') do
        simple = recording_sync
        result = simple.pull_dir('root', base, prune: true)

        assert_equal [1, ['a.txt']], [result.deleted, Dir.children(base)]
        assert_logged(simple, 'Deleted', File.join(base, 'stale.txt'))
      end
    end
  end

  def test_prune_removes_a_local_subtree_the_remote_does_not_have
    with_local_dir do |base|
      write_file(base, 'stale/deep/x.txt', 'old')

      with_ftp('root' => []) do
        result = sync.pull_dir('root', base, prune: true)

        # The file, its directory and the now-empty parent: three deletions.
        assert_equal 3, result.deleted
        assert_empty Dir.children(base)
      end
    end
  end

  def test_nothing_is_pruned_by_default
    with_local_dir do |base|
      write_file(base, 'stale.txt', 'old')

      with_ftp('root' => []) do
        result = sync.pull_dir('root', base)

        assert_equal [0, ['stale.txt']], [result.deleted, Dir.children(base)]
      end
    end
  end

  def test_pull_does_not_prune_when_the_listing_failed
    with_local_dir do |base|
      write_file(base, 'stale.txt', 'old')

      with_ftp('root' => []) do |ftp|
        ftp.fail_lists << 'root'
        result = sync.pull_dir('root', base, prune: true, skip_errors: true)

        assert_equal [1, 0], [result.failed, result.deleted]
        assert_equal ['stale.txt'], Dir.children(base)
      end
    end
  end

  # A listing that died halfway is not an empty directory: nothing read from it
  # may be acted on, neither as a transfer nor as grounds for deleting.
  def test_pull_ignores_a_listing_that_failed_after_some_entries
    with_local_dir do |base|
      write_file(base, 'stale.txt', 'old')

      with_ftp({ 'root' => [file_entry('a.txt')] }, 'root/a.txt' => 'data') do |ftp|
        ftp.fail_lists_after['root'] = '426 Connection closed; transfer aborted'

        result = sync.pull_dir('root', base, prune: true, skip_errors: true)

        assert_equal [1, 0, 0], [result.failed, result.transferred, result.deleted]
        assert_equal %w[stale.txt], Dir.children(base)
      end
    end
  end

  def test_pull_does_not_prune_when_an_entry_could_not_be_interpreted
    with_local_dir do |base|
      write_file(base, 'stale.txt', 'old')

      with_ftp('root' => [file_entry('a.txt'), unparseable_entry('garbage')]) do
        simple = recording_sync
        result = simple.pull_dir('root', base, prune: true)

        assert_equal [1, 0], [result.failed, result.deleted]
        assert_equal %w[a.txt stale.txt], Dir.children(base)
        assert_logged(simple, 'Not pruning', 'incomplete')
      end
    end
  end

  # A skipped remote entry still counts as present: a local file that matches a
  # remote symlink is not stale just because the link is not transferred.
  def test_pull_prune_keeps_a_local_file_matching_a_skipped_remote_entry
    with_local_dir do |base|
      write_file(base, 'link.txt', 'local copy')

      with_ftp('root' => [symlink_entry('link.txt')]) do
        result = sync.pull_dir('root', base, prune: true)

        assert_equal [0, ['link.txt']], [result.deleted, Dir.children(base)]
        assert_equal 1, result.skipped
      end
    end
  end

  # The link is unlinked, never entered: pruning must not delete through it.
  def test_pull_prune_unlinks_a_local_symlink_without_following_it
    with_local_dir do |base|
      with_local_dir do |elsewhere|
        write_file(elsewhere, 'target.txt', 'keep me')
        File.symlink(elsewhere, File.join(base, 'link'))

        with_ftp('root' => []) do
          result = sync.pull_dir('root', base, prune: true)

          assert_equal [1, 'keep me'], [result.deleted, File.read(File.join(elsewhere, 'target.txt'))]
          refute_path_exists File.join(base, 'link')
        end
      end
    end
  end

  def test_push_prune_deletes_a_remote_file_the_local_tree_does_not_have
    with_local_dir do |base|
      write_files(base, 'a.txt' => 'one')

      with_ftp('root' => [file_entry('a.txt'), file_entry('stale.txt')]) do |ftp|
        ftp.contents['root/stale.txt'] = 'old'
        simple = recording_sync
        result = simple.push_dir(base, 'root', prune: true)

        assert_equal [1, ['root/a.txt']], [result.deleted, ftp.contents.keys.sort]
        assert_logged(simple, 'Deleted', 'root/stale.txt')
      end
    end
  end

  def test_push_prune_removes_a_remote_subtree_the_local_tree_does_not_have
    with_local_dir do |base|
      write_files(base, 'a.txt' => 'one')
      listings = { 'root' => [file_entry('a.txt'), dir_entry('stale')],
                   'root/stale' => [file_entry('x.txt'), dir_entry('deep')],
                   'root/stale/deep' => [file_entry('y.txt')] }
      contents = { 'root/stale/x.txt' => 'old', 'root/stale/deep/y.txt' => 'old' }

      with_ftp(listings, contents) do |ftp|
        result = sync.push_dir(base, 'root', prune: true)

        assert_equal 4, result.deleted
        assert_equal ['root/a.txt'], ftp.contents.keys.sort
        # Bottom-up, and never the destination root itself.
        assert_equal %w[root/stale/deep root/stale], ftp.rmdir_calls
      end
    end
  end

  def test_push_prune_does_not_remove_the_destination_root
    with_local_dir do |base|
      with_ftp('root' => [file_entry('stale.txt')]) do |ftp|
        ftp.contents['root/stale.txt'] = 'old'
        result = sync.push_dir(base, 'root', prune: true)

        assert_equal [1, []], [result.deleted, ftp.rmdir_calls]
      end
    end
  end

  def test_push_prune_leaves_a_remote_symlink_alone
    with_local_dir do |base|
      write_files(base, 'a.txt' => 'one')

      with_ftp('root' => [file_entry('a.txt'), symlink_entry('link')]) do |ftp|
        result = sync.push_dir(base, 'root', prune: true)

        assert_equal [0, false], [result.deleted, ftp.deleted.include?('root/link')]
      end
    end
  end

  def test_nothing_is_pruned_on_push_by_default
    with_local_dir do |base|
      write_files(base, 'a.txt' => 'one')

      with_ftp('root' => [file_entry('a.txt'), file_entry('stale.txt')]) do |ftp|
        ftp.contents['root/stale.txt'] = 'old'
        result = sync.push_dir(base, 'root')

        assert_equal [0, %w[root/a.txt root/stale.txt]], [result.deleted, ftp.contents.keys.sort]
      end
    end
  end

  def test_push_does_not_prune_when_the_listing_failed
    with_local_dir do |base|
      write_files(base, 'a.txt' => 'one')

      with_ftp('root' => [file_entry('a.txt'), file_entry('stale.txt')]) do |ftp|
        ftp.contents['root/stale.txt'] = 'old'
        ftp.fail_lists << 'root'
        result = sync.push_dir(base, 'root', prune: true, skip_errors: true)

        assert_equal [1, 0], [result.failed, result.deleted]
        assert_equal %w[root/a.txt root/stale.txt], ftp.contents.keys.sort
      end
    end
  end

  # Entries read before the listing died are still a prefix, not a statement of
  # what the remote directory holds, so they are not grounds for deleting.
  def test_push_does_not_prune_after_a_listing_that_failed_part_way
    with_local_dir do |base|
      write_files(base, 'a.txt' => 'one')

      with_ftp('root' => [file_entry('a.txt'), file_entry('stale.txt')]) do |ftp|
        ftp.contents['root/stale.txt'] = 'old'
        ftp.fail_lists_after['root'] = '426 Connection closed; transfer aborted'

        result = sync.push_dir(base, 'root', prune: true, skip_errors: true)

        assert_equal [1, 0], [result.failed, result.deleted]
        assert_equal %w[root/a.txt root/stale.txt], ftp.contents.keys.sort
      end
    end
  end

  def test_push_does_not_prune_when_an_entry_could_not_be_interpreted
    with_local_dir do |base|
      write_files(base, 'a.txt' => 'one')

      with_ftp('root' => [file_entry('a.txt'), unparseable_entry('garbage')]) do |ftp|
        ftp.contents['root/garbage'] = 'old'
        simple = recording_sync
        result = simple.push_dir(base, 'root', prune: true)

        assert_equal [1, 0], [result.failed, result.deleted]
        assert_logged(simple, 'Not pruning', 'incomplete')
      end
    end
  end

  # :since and :prune share the one listing they both need.
  def test_push_lists_once_for_since_and_prune
    with_local_dir do |base|
      local_path = write_file(base, 'a.txt', 'data')
      set_mtime(local_path, Time.now - 3600)
      entries = [file_entry('a.txt', mtime: Time.now - 3600, filesize: 4), file_entry('stale.txt')]

      with_ftp({ 'root' => entries }, 'root/stale.txt' => 'old') do |ftp|
        result = sync.push_dir(base, 'root', since: true, prune: true)

        # One listing of the destination serves both decisions.
        assert_equal [0, 1, 1], [result.transferred, result.deleted, ftp.list_calls.count('root')]
      end
    end
  end
end
