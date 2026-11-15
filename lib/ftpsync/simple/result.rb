# frozen_string_literal: true

module FtpSync
  # Reopened so that each part of the client can live in its own file.
  class Simple
    # Outcome of one top-level sync. +transferred+ counts files that reached
    # their destination, +skipped+ counts entries deliberately left alone (up to
    # date under :since, symlinks and other non-files, protected local files,
    # leftover partial files), +deleted+ counts entries pruned under :prune, and
    # +failed+ counts errors :skip_errors swallowed together with listing entries
    # that could not be interpreted. Every failure is also listed in +errors+ as
    # a [path, message] pair.
    Result = Struct.new(:transferred, :skipped, :failed, :errors, :deleted)
  end
end
