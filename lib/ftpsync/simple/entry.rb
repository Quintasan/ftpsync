# frozen_string_literal: true

module FtpSync
  # Reopened so that each part of the client can live in its own file.
  class Simple
    # One listing entry, normalised from an MLSx fact set or a parsed LIST line
    # so that nothing above this class needs to know which command answered.
    #
    # +mtime_source+ records where the timestamp came from: MLSD dates entries
    # in UTC with second precision, while LIST is the server's wall clock with
    # minute precision, and the two cannot be compared with the same tolerance.
    # A nil type means the source did not say what the entry is, which the
    # listing reports as a failure; a nil mtime means the source carried no
    # usable time, so nothing can be proven current.
    class Entry
      # MLSx type fact values this library understands. Anything else, including
      # a missing fact, leaves the type unknown.
      MLSX_TYPES = {
        'file' => :file,
        'dir' => :dir,
        'os.unix=slink' => :symlink,
        'os.unix=symlink' => :symlink,
        'os.unix=chr' => :device,
        'os.unix=blk' => :device,
        'os.unix=fifo' => :device,
        'os.unix=socket' => :device
      }.freeze

      # The pseudo entries every directory listing may carry: "cdir" and "pdir"
      # in MLSx, and the same names as ordinary entries in LIST output.
      PSEUDO_NAMES = %w[. ..].freeze

      # Builds an entry from Net::FTP::MLSxEntry facts. The cdir and pdir types
      # describe the listed directory itself, so they yield nothing.
      def self.from_mlsx(mlsx_entry)
        facts = mlsx_entry.facts
        type = facts['type'].to_s.downcase
        return if %w[cdir pdir].include?(type)

        new(mlsx_entry.pathname, MLSX_TYPES[type], facts['size'].to_i, facts['modify'], :mlsx)
      end

      # Builds an entry from a net-ftp-list entry.
      def self.from_list(list_entry)
        new(list_entry.basename, list_entry.type, list_entry.filesize.to_i, list_entry.mtime, :list)
      end

      attr_reader :basename, :type, :filesize, :mtime, :mtime_source

      def initialize(basename, type, filesize, mtime, mtime_source)
        @basename = basename
        @type = type
        @filesize = filesize
        @mtime = mtime
        @mtime_source = mtime_source
      end

      def dir?
        type == :dir
      end

      def file?
        type == :file
      end

      def pseudo?
        PSEUDO_NAMES.include?(basename)
      end
    end
  end
end
