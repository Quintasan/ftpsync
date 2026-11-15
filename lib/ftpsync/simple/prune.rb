# frozen_string_literal: true

module FtpSync
  # Reopened so that each part of the client can live in its own file.
  class Simple
    # :prune deletes what the source no longer has. Both directions refuse to
    # delete anything they cannot fully account for: a directory whose listing
    # failed or held uninterpretable entries is left untouched, and no symlink is
    # ever followed or removed. The destination root is never a candidate, only
    # the entries inside it.
    module Prune
      private

      def prune_local_directory(localpath, remote_names, status, session)
        return unless session.options[:prune]
        return refuse_pruning(localpath, status) unless status == :ok

        Dir.children(localpath).sort.each do |basename|
          next if remote_names.key?(basename)

          local_path = File.join(localpath, basename)
          remove_local_entry(local_path, session) if prunable?(local_path, session.local_root, session)
        end
      end

      # An entry a filter pattern keeps out of the sync is out of reach of
      # :prune as well: the pattern says it is deliberately not compared. A
      # directory that is pruned as a whole still takes its subtree with it.
      def prunable?(path, root, session)
        !filtered_out?(relative_path(path, root), plain_directory?(path), session)
      end

      def remove_local_entry(local_path, session)
        if File.directory?(local_path) && !File.symlink?(local_path)
          remove_local_tree(local_path, session)
        else
          File.unlink(local_path) unless dry_run?(session)
          deleted_entry(local_path, session)
        end
      end

      # A directory is emptied entry by entry so that a symlink is unlinked
      # rather than followed into its target. A dry run walks the same entries,
      # so that it counts what a real run would have deleted.
      def remove_local_tree(local_path, session)
        Dir.children(local_path).sort.each do |basename|
          remove_local_entry(File.join(local_path, basename), session)
        end
        Dir.rmdir(local_path) unless dry_run?(session)
        deleted_entry(local_path, session)
      end

      def prune_remote_directory(remotepath, remote_entries, local_names, status, session)
        return unless session.options[:prune]
        return refuse_pruning(remotepath, status) unless status == :ok

        remote_entries.each do |basename, entry|
          next if local_names.key?(basename)

          remote_path = join_remote(remotepath, basename)
          remove_remote_entry(remote_path, entry, session) if prunable?(remote_path, session.remote_root, session)
        end
      end

      # Deletes one remote entry and reports whether it is gone. A directory is
      # only removed once its whole subtree was listed and understood, so partial
      # knowledge never deletes anything.
      def remove_remote_entry(remote_path, entry, session)
        return nil unless remove_remote_content(remote_path, entry, session)

        deleted_entry(remote_path, session)
        true
      rescue Net::FTPError => e
        raise unless session.options[:skip_errors]

        report_error(session.result, remote_path, e)
        nil
      end

      def remove_remote_content(remote_path, entry, session)
        if entry.dir?
          return nil unless remove_remote_tree(remote_path, session)

          @connection.rmdir(remote_path) unless dry_run?(session)
        elsif entry.file?
          @connection.delete(remote_path) unless dry_run?(session)
        else
          log "Not pruning #{remote_path}: #{entry_type(entry)}"
          return nil
        end
        true
      end

      def remove_remote_tree(remote_path, session)
        entries = {}
        status = each_entry(remote_path, session) { |entry| entries[entry.basename] = entry }
        return unless status == :ok

        entries.each_value do |entry|
          return nil unless remove_remote_entry(join_remote(remote_path, entry.basename), entry, session)
        end
        true
      end

      # A dry run counts the same entries and says what it would have removed,
      # including the directories a real run would leave empty.
      def deleted_entry(path, session)
        session.result.deleted += 1
        log dry_run?(session) ? "Would delete #{path}" : "Deleted #{path}"
      end

      # Pruning is only safe on a listing that was read and interpreted whole;
      # saying so is better than quietly doing nothing.
      def refuse_pruning(path, status)
        log "Not pruning #{path}: the listing was #{status == :partial ? 'incomplete' : 'unreadable'}"
        nil
      end
    end
  end
end
