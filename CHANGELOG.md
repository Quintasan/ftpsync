# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-10-21

### Added

- `pull_dir` and `push_dir` return a `FtpSync::Simple::Result` with
  `transferred`, `skipped` and `failed` counts and an `errors` array of
  `[path, message]` pairs. Errors that `:skip_errors` swallows appear there as
  well as in the verbose log.
- Atomic uploads: a file is uploaded as `<remote>.ftpsync-part` and renamed into
  place, so an upload that fails halfway no longer destroys the remote copy it
  was replacing. A server without `RNFR`/`RNTO` falls back to an in-place
  upload, which is logged once per connection. `atomic_uploads: false` turns
  the behaviour off.
- `:protect_local` on `pull_dir` skips files that are newer locally than on the
  server instead of overwriting them.
- `mtime_tolerance:` (default 60 seconds) sets how far a local file may lead
  the remote timestamp before an upload counts as changed. It must be a
  non-negative number and is validated in the constructor. It applies when the
  remote time comes from `LIST`; an `MDTM` timestamp, which has second
  precision and is timezone independent, is compared with a 2-second tolerance.
- Warnings, visible with `:verbose`: a pull that finds a file that is newer
  locally, a transferred size that disagrees with the listing, and a leftover
  `*.ftpsync-part` file that is not uploaded.
- `prune: true` on either direction deletes what the source no longer has:
  files, and whole directories when their subtree is absent too. It is off by
  default, never touches the destination root, and only deletes from a listing
  that was read and interpreted whole, so a failed or partly unreadable listing
  deletes nothing. Every deletion is logged.
- `Result#deleted` counts the entries `:prune` removed, next to `transferred`,
  `skipped` and `failed`.

### Changed

- Unknown option keys raise `ArgumentError` naming the key, in the constructor
  and in `pull_dir`/`push_dir`, before any connection is made. A typo such as
  `ssll:` can no longer leave the connection unencrypted. `nil` options are
  treated as an empty hash.
- Remote paths must be strings; an empty remote path still means the login
  directory, as in 0.1.0. Local paths must be non-empty strings. Anything else
  raises `ArgumentError` before connecting, instead of a `TypeError` or a `550`
  from the server.
- Pulling logs and counts entries that are neither files nor directories
  (symlinks, devices, unparseable listing lines), as pushing already did.
- A failed `MKD` is still tolerated as "already exists" when the listing cannot
  prove otherwise, including the quirk where a server answers `LIST` for a
  missing path with an empty listing. A file in the way of a directory is
  reported instead of passing as an existing directory: the verdict comes from
  the listing of the path's parent, and only a non-directory entry with that
  name counts as proof, so a directory that happens to contain one entry of the
  same name stays a directory.
- `push_dir` accepts only `:since` and `:skip_errors`. `:protect_local`, which
  only `pull_dir` understands, raises the same `ArgumentError` as any other
  unknown option instead of being ignored.
- A remote directory that was created or confirmed is remembered for the rest
  of the sync, so a deep tree costs one `MKD` probe per directory instead of
  one per ancestor.
- The server, port, user, password and passive mode are read when a connection
  is opened. Changing them afterwards does not move an open connection, and log
  lines name the endpoint that was actually connected.
- Downloads use `getbinaryfile` explicitly instead of relying on `Net::FTP`'s
  binary flag.
- Listings come from `MLSD` when the server implements it. MLSD types every
  entry and dates it in UTC with second precision, so it does not depend on the
  server's locale the way `LIST` parsing does. A server without MLSD is asked
  once per connection, the fallback to `LIST` is logged, and nothing else
  changes. `.`/`..` and `cdir`/`pdir` entries are always ignored.
- A listing entry whose type cannot be determined is a reported failure, not a
  skip: it is counted in `failed`, listed in `errors` as
  `[path, "unusable listing entry: type unknown"]` and logged. A non-English
  server locale used to turn every `LIST` line into such an entry, so a pull
  could transfer nothing and report success. Under `:since`, a directory whose
  listing could not be read whole is not uploaded into, because freshness
  cannot be proven.
- `:since` treats a file whose remote entry carries no usable modification time
  as changed and downloads it; `:protect_local` keeps the local copy in that
  case, since nothing proves the remote copy is the newer one.

### Removed

- `FtpSync::Simple::MTIME_TOLERANCE`, replaced by the `mtime_tolerance:` option
  and the tolerance that follows the timestamp's provenance.

### Fixed

- `pull_dir` no longer creates the local directory before the remote listing
  succeeds, so a wrong remote path no longer leaves an empty tree behind.
- A failed `MKD` caused by a file sitting at that path is no longer swallowed
  as "the directory already exists": the parent listing proves the file is in
  the way.
- Leftover `*.ftpsync-part` files from an interrupted pull are skipped instead
  of uploaded to the server.
- A `:since` push no longer overwrites files in a directory whose remote
  listing failed. An unreadable listing proves nothing about freshness, so the
  directory is reported (`failed`/`errors`, and the verbose log) and left
  alone instead of re-uploading every local file over a possibly newer remote
  copy.

### Upgrading from 0.1.0

- `pull_dir`/`push_dir` now return a `FtpSync::Simple::Result`. Code that
  ignored the return value is unaffected; code that read the old arrays must
  use `result.transferred`, `result.skipped`, `result.failed` and
  `result.errors`. Block callbacks still receive the same single path argument.
- Uploads are atomic by default and need `RNFR`/`RNTO`. On a server that
  cannot rename, the library logs that once per connection and uploads in
  place; `atomic_uploads: false` keeps the previous behaviour everywhere.
- A typo in an option name now raises `ArgumentError` instead of being ignored.
  `:atomic_uploads` is a constructor option, not a per-call one.
- On a server that supports `MDTM`, a same-size file modified at least two
  seconds after its last upload is now uploaded. The old 60-second window was
  meant for `LIST` precision but was also applied to `MDTM`; it hid such edits.
  Set `mtime_tolerance:` only for the `LIST` fallback.
- Passing `:protect_local` to `push_dir` now raises `ArgumentError`; the
  option only applies to `pull_dir`.
- `nil` options are accepted as an empty hash, and path arguments are validated
  before connecting, so mistakes surface as `ArgumentError` rather than as a
  `TypeError` during a transfer. An empty remote path still means the login
  directory for both directions; only local paths must be non-empty.
- `:prune` is opt-in and per call; nothing is deleted unless it is passed.
  Check `Result#deleted` to see what a run removed.
- After upgrading against a server that speaks MLSD, the first `:since` pull
  may re-download a file once: the timestamp stored by earlier versions came
  from `LIST` (server wall clock, minute precision) and is replaced by the
  server's UTC stamp. The run after that compares equal again.
- A `LIST` line the parser cannot read now fails the entry instead of skipping
  it. Runs against a non-English server that used to "succeed" while
  transferring little or nothing will now report those entries in
  `Result#failed`/`#errors`.

## [0.1.0] - 2026-10-15

### Added

- `FtpSync::Simple#push_dir`, recursive uploads that create missing remote
  directories, with `:since` and `:skip_errors` support. `:since` compares
  against the `MDTM` time, which is in UTC, falling back to the `LIST`
  timestamp on servers that do not implement `MDTM`.
- `:ssl`, `:implicit_ftps`, `:open_timeout` and `:read_timeout` options.

### Changed

- `:passive` now defaults to `true`. Active mode has to be requested with
  `passive: false`.
- `:since` now stores the server modification time on downloaded files, so a
  repeated pull recognises its own work instead of comparing against the local
  clock. `LIST` timestamps still have minute precision; see the README.
- `:skip_errors` now rescues `Net::FTPError` from directory listings as well as
  from transfers.
- Downloads are written to a `<name>.ftpsync-part` file and renamed into place
  once the transfer completes.

### Fixed

- The connection is closed when a sync raises, instead of leaving a socket open
  and the instance unusable for the next call.
- `:skip_errors` now also covers remote directory creation while pushing.
- `close!` no longer raises `NoMethodError` when no connection was established.
- A failed download no longer replaces a good local file with a truncated one.
