# frozen_string_literal: true

module FtpSync
  # Reopened so that each part of the client can live in its own file.
  class Simple
    # What :exclude and :include mean for one path, and the relative path they
    # are matched against. Both directions ask the same questions, so a pattern
    # cannot mean something different on the way in and on the way out.
    module Filtering
      private

      # +path+ without +root+, which is what the :exclude and :include patterns
      # are matched against. The two sides of a sync sit at different places, so
      # each is asked with its own root, and both then read the same relative
      # path.
      def relative_path(path, root)
        path.delete_prefix(root.to_s).delete_prefix('/')
      end

      # A directory that is not a link to one, which is what both sides mean when
      # they decide whether to descend.
      def plain_directory?(path)
        File.directory?(path) && !File.symlink?(path)
      end

      # Whether a pattern list keeps +path+ out. A directory is only ever dropped
      # on purpose: :include leaves directories alone, because the files it names
      # may live below them. A pattern that names a directory drops its subtree
      # with it.
      def filtered_out?(path, directory, session)
        return true if matches_any?(session.options[:exclude], path)
        return false if directory

        patterns = Array(session.options[:include])
        !patterns.empty? && !matches_any?(patterns, path)
      end

      # Whether a pattern keeps a listed entry out, in which case it is counted
      # as skipped and nothing else happens to it or, for a directory, below it.
      def skip_filtered_entry?(path, entry, session)
        return false unless filtered_out?(relative_path(path, session.remote_root), entry.dir?, session)

        skip_entry(path, FILTERED_OUT, session)
        true
      end

      # "*" stops at a "/" so that a pattern cannot surprise the caller by
      # matching deeper than it spells out; "**/" is the explicit way to descend.
      def matches_any?(patterns, path)
        Array(patterns).any? do |pattern|
          File.fnmatch?(pattern, path, File::FNM_PATHNAME | File::FNM_DOTMATCH)
        end
      end
    end
  end
end
