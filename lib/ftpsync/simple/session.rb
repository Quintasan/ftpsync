# frozen_string_literal: true

module FtpSync
  # Reopened so that each part of the client can live in its own file.
  class Simple
    # State of one top-level sync: the caller's options, the tally that becomes
    # the return value, the remote directories already created or confirmed, and
    # the two paths the sync started from, which the filter patterns are matched
    # against. It is dropped when the sync ends, which is exactly how long those
    # stay valid, and it keeps a nested sync started from a callback independent.
    class Session
      attr_reader :options, :result
      attr_accessor :local_root, :remote_root

      def initialize(options)
        @options = options
        @result = Result.new(0, 0, 0, [], 0)
        @known_directories = {}
      end

      def known_directory?(path)
        @known_directories.key?(path)
      end

      def remember_directory(path)
        @known_directories[path] = true
      end
    end
  end
end
