# frozen_string_literal: true

require 'support/sync_test_case'

# :exclude and :include decide what is part of a sync, on both sides. Patterns
# are globs matched against the path inside the synced tree, so they do not
# depend on where the tree sits in the local filesystem.
class FtpsyncFilterTest < SyncTestCase
  def test_exclude_skips_a_matching_file
    with_local_dir do |base|
      with_ftp({ 'root' => [file_entry('a.log'), file_entry('b.txt')] }) do |ftp|
        result = sync.pull_dir('root', base, exclude: '*.log')

        assert_equal [1, 1, ['b.txt']], [result.transferred, result.skipped, Dir.children(base)]
        assert_equal ['root/b.txt'], ftp.downloaded.map(&:first)
      end
    end
  end

  def test_exclude_drops_a_directory_with_its_subtree
    with_local_dir do |base|
      listings = { 'root' => [dir_entry('keep'), dir_entry('tmp')],
                   'root/keep' => [file_entry('a.txt')], 'root/tmp' => [file_entry('b.txt')] }
      with_ftp(listings) do |ftp|
        sync.pull_dir('root', base, exclude: 'tmp')

        assert_equal ['keep'], Dir.children(base)
        assert_equal ['root/keep/a.txt'], ftp.downloaded.map(&:first)
      end
    end
  end

  def test_include_limits_the_pull_to_matching_files
    with_local_dir do |base|
      with_ftp({ 'root' => [file_entry('a.txt'), file_entry('b.md')] }) do |ftp|
        result = sync.pull_dir('root', base, include: '*.txt')

        assert_equal [1, ['a.txt']], [result.transferred, Dir.children(base)]
        assert_equal ['root/a.txt'], ftp.downloaded.map(&:first)
      end
    end
  end

  def test_exclude_wins_over_include
    with_local_dir do |base|
      with_ftp({ 'root' => [file_entry('a.txt'), file_entry('b.txt')] }) do |_ftp|
        sync.pull_dir('root', base, include: '*.txt', exclude: 'b*')

        assert_equal ['a.txt'], Dir.children(base)
      end
    end
  end

  def test_a_pattern_is_matched_against_the_path_inside_the_sync
    with_local_dir do |base|
      listings = { 'root' => [dir_entry('docs'), dir_entry('src')],
                   'root/docs' => [file_entry('a.txt')], 'root/src' => [file_entry('b.txt')] }
      with_ftp(listings) do |ftp|
        sync.pull_dir('root', base, exclude: 'docs/*')

        # "docs" itself is not matched, so it is still walked and created; only
        # the files inside it are left out.
        assert_equal %w[docs src], Dir.children(base).sort
        assert_equal ['root/src/b.txt'], ftp.downloaded.map(&:first)
      end
    end
  end

  def test_a_double_star_pattern_matches_at_any_depth
    with_local_dir do |base|
      listings = { 'root' => [file_entry('top.log'), dir_entry('sub')],
                   'root/sub' => [file_entry('deep.log'), file_entry('keep.txt')] }
      with_ftp(listings) do |ftp|
        result = sync.pull_dir('root', base, exclude: '**/*.log')

        assert_equal [1, 2], [result.transferred, result.skipped]
        assert_equal ['root/sub/keep.txt'], ftp.downloaded.map(&:first)
      end
    end
  end

  def test_a_star_does_not_cross_a_directory_separator
    with_local_dir do |base|
      with_ftp({ 'root' => [dir_entry('docs')], 'root/docs' => [file_entry('a.txt')] }) do |ftp|
        sync.pull_dir('root', base, exclude: '*.txt')

        assert_equal ['root/docs/a.txt'], ftp.downloaded.map(&:first)
      end
    end
  end

  def test_include_leaves_a_directory_alone_so_its_files_can_match
    with_local_dir do |base|
      listings = { 'root' => [dir_entry('sub')],
                   'root/sub' => [file_entry('a.txt'), file_entry('b.md')] }
      with_ftp(listings) do |ftp|
        sync.pull_dir('root', base, include: 'sub/*.txt')

        assert_equal [['sub'], ['a.txt']], [Dir.children(base), Dir.children(File.join(base, 'sub'))]
        assert_equal ['root/sub/a.txt'], ftp.downloaded.map(&:first)
      end
    end
  end

  def test_push_skips_a_file_excluded_from_the_sync
    with_local_dir do |base|
      write_files(base, 'a.log' => 'log', 'b.txt' => 'text')

      with_ftp('root' => []) do |ftp|
        result = sync.push_dir(base, 'root', exclude: '*.log')

        assert_equal [1, 1], [result.transferred, result.skipped]
        assert_equal ['root/b.txt'], ftp.uploaded.map(&:last)
      end
    end
  end

  def test_prune_keeps_an_excluded_local_file
    with_local_dir do |base|
      write_file(base, 'stale.log', 'old')

      with_ftp('root' => []) do
        result = sync.pull_dir('root', base, prune: true, exclude: '*.log')

        assert_equal [0, ['stale.log']], [result.deleted, Dir.children(base)]
      end
    end
  end

  def test_prune_keeps_an_excluded_remote_file
    with_local_dir do |base|
      with_ftp({ 'root' => [file_entry('stale.log')] }, 'root/stale.log' => 'old') do |ftp|
        result = sync.push_dir(base, 'root', prune: true, exclude: '*.log')

        assert_equal [0, 'old'], [result.deleted, ftp.contents['root/stale.log']]
      end
    end
  end
end
