# FtpSync

[![CI](https://github.com/Quintasan/ftpsync/actions/workflows/ci.yml/badge.svg)](https://github.com/Quintasan/ftpsync/actions/workflows/ci.yml)

FtpSync copies a directory tree between your machine and an FTP server, in
either direction. FTP (File Transfer Protocol) is the older file-transfer
protocol still offered by many hosting providers. Give it a host, a username
and a password; it walks both trees, creates missing directories on the
receiving side, and copies files byte for byte. `pull_dir` downloads,
`push_dir` uploads, and `:since` skips unchanged files.

## Requirements

* Ruby 2.6 or newer, with `net-ftp` 0.3.9 or newer (for the TLS and timeout
  options FtpSync passes) and `net-ftp-list` 3.2.8 or newer.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'ftpsync'
```

Then run `bundle`, or install it yourself:

    $ gem install ftpsync

## Quick start

```ruby
require 'ftpsync'
sync = FtpSync::Simple.new('ftp.example.com', 'username', 'password')
sync.pull_dir('/remote/site', './site')  # download
sync.push_dir('./site', '/remote/site')  # upload
```

## Download a directory tree

```ruby
sync.pull_dir('reports/2024', './reports')
```

`pull_dir` recreates the remote tree under the local path. Local directories are
created only after their remote listing succeeds, so a typo'd remote path leaves
nothing behind. Existing local files are replaced; pass `:protect_local` to keep
one that is newer than the remote copy. An empty remote path means the login
directory; a local path must be a non-empty string.

## Upload a directory tree

```ruby
sync.push_dir('./public', '/var/www/public')
```

`push_dir` mirrors the local tree on the server, creating every missing part of
the remote path. Local symlinks, `.ftpsync-part` leftovers and anything that is
not a regular file or directory are skipped. The local path must be a directory,
or `push_dir` raises `ArgumentError` before connecting.

Uploads are atomic by default: data goes to `<remote>.ftpsync-part` and is
renamed into place when the transfer finishes, so a failed `STOR` is just a
failed upload and leaves the remote copy untouched. Only a genuine `RNFR`/`RNTO`
rejection falls back to an in-place upload, logged once per connection;
`atomic_uploads: false` forces in-place uploads.

## Skip files that did not change (`:since`)

```ruby
sync.pull_dir('reports/2024', './reports', since: true)
sync.push_dir('./public', '/var/www/public', since: true)
```

With `:since`, a file is skipped when its size matches and the timestamps show
no newer change; skipped files count in `result.skipped` and do not reach the
block.

* **Downloading** stores the server's `LIST` timestamp on the downloaded file
  and skips a file when its size matches and the remote copy is not newer. A
  locally edited file is kept.
* **Uploading** cannot carry the local modification time: the server stamps the
  upload with its own clock. A same-size file is skipped when it is less than
  the tolerance newer than the remote timestamp.

For uploads FtpSync reads `MDTM` (UTC, second precision) and allows 2 seconds of
clock jitter. Without `MDTM` it uses `LIST`, whose local-time reading is treated
as UTC, so the comparison can be off by the server's UTC offset and uses
`:mtime_tolerance` (60 seconds by default) for minute rounding. A backdated file
(`cp -p`, restored build output) looks unchanged.

With `:skip_errors`, a failed remote listing leaves that directory's files
unuploaded and records the failure in `result.failed`/`result.errors`: an
unreadable listing cannot prove a remote copy is current.

## Run code for each transferred file

The block receives the local path when downloading and the remote path when
uploading. It runs only after a complete transfer, never for a skipped file; an
exception from it stops the sync and is not caught by `:skip_errors`.

```ruby
sync.pull_dir('reports/2024', './reports') { |file| puts "downloaded #{file}" }
sync.push_dir('./public', '/var/www/public') { |file| puts "uploaded #{file}" }
```

## Read the result of a sync

Both methods return a `FtpSync::Simple::Result` with `transferred`, `skipped`,
`failed` and `errors`. `skipped` counts entries left alone on purpose (up-to-date
files, non-files, protected files, leftovers); `failed` counts errors
`:skip_errors` swallowed, each also in `errors` as a `[path, message]` pair.

```ruby
result = sync.pull_dir('reports', './reports', skip_errors: true)
puts "#{result.transferred} transferred, #{result.skipped} skipped, #{result.failed} failed"
result.errors.each { |path, message| puts "#{path}: #{message}" }
```

## Keep going after server errors (`:skip_errors`)

```ruby
sync.pull_dir('reports', './reports', skip_errors: true, verbose: true)
```

`:skip_errors` catches `Net::FTPError` from listings, downloads, uploads and
remote directory creation, logs it, and continues. Each caught error increments
`result.failed` and is recorded in `result.errors`; `:verbose` prints the same
messages to stderr. Local filesystem errors, dropped sockets and exceptions from
your block still raise.

## Connect over TLS

FTPS is FTP wrapped in TLS, the encryption HTTPS uses. **Explicit FTPS** starts
as plain FTP on port 21 and upgrades with `AUTH TLS` (`ssl: true`). **Implicit
FTPS** starts TLS immediately, usually on port 990 (`implicit_ftps: true`, and
set the port yourself).

```ruby
FtpSync::Simple.new('ftp.example.com', 'user', 'pass', ssl: true)
FtpSync::Simple.new('ftp.example.com', 'user', 'pass',
                    implicit_ftps: true, port: 990)
```

`:implicit_ftps` sets the default of `:ssl` to `true`. A hash for `:ssl` is
passed to `OpenSSL::SSL::SSLContext#set_params`; use it for options such as
`ca_file` and `verify_mode`.

## Reuse or close the connection

`pull_dir` and `push_dir` open a connection when needed and close it when the
outermost sync finishes, even if it raised. `connect!` connects and logs in
immediately, so bad credentials fail before a long sync; `close!` closes and is
safe to call more than once. A sync started inside a per-file block reuses the
connection; a top-level sync always closes it at the end.

## Options

Unknown option keys raise `ArgumentError` naming the key before connecting;
invalid paths raise it too. `nil` options mean an empty hash. Local paths must be
non-empty strings; remote paths may be empty. `FtpSync::Simple.new` accepts:

| Option             | Default                                  | Description |
|--------------------|------------------------------------------|-------------|
| `:port`            | `21`                                     | Port to connect to. Use `990` for implicit FTPS. |
| `:passive`         | `true`                                   | Passive mode: the client opens each data connection, which works through NAT and most firewalls. Set to `false` for active mode. |
| `:verbose`         | `false`                                  | Log connection, transfer, skip and error messages to stderr. |
| `:ssl`             | `false`, or `true` with `:implicit_ftps` | Wrap the connection in TLS. `true` uses OpenSSL defaults; a hash is passed to `OpenSSL::SSL::SSLContext#set_params`. |
| `:implicit_ftps`   | `false`                                  | Start TLS immediately (implicit FTPS). Sets the default of `:ssl` to `true`. |
| `:open_timeout`    | `30`                                     | Seconds to wait for the connection to open. |
| `:read_timeout`    | `60`                                     | Seconds to wait for one read from the server. |
| `:mtime_tolerance` | `60`                                     | `LIST` upload tolerance in seconds; a non-negative Numeric (Float allowed), otherwise `ArgumentError`. `MDTM` uses a fixed 2-second tolerance. |
| `:atomic_uploads`  | `true`                                   | Upload to `<remote>.ftpsync-part` and rename into place. Set to `false` to write directly to the destination. |

`pull_dir` accepts `:since`, `:skip_errors` and `:protect_local`; `push_dir`
only `:since` and `:skip_errors`. All default to `false`; `:protect_local` on
`push_dir` raises like any unknown key. `:verbose` writes through
`FtpSync::Simple#log`, which can be overridden.

## Behaviour worth knowing

* Transfers are binary; no line endings are translated.
* Downloads and atomic uploads use `.ftpsync-part` side files and leave the
  destination untouched on failure. Uploads are atomic by default;
  `atomic_uploads: false`, or a genuine `RNFR`/`RNTO` rejection, falls back to
  an in-place upload.
* Local files ending in `.ftpsync-part` are never uploaded.
* A pull logs and counts entries that are neither regular files nor directories:
  symlinks, devices and listing lines it cannot parse.
* A pull replaces a newer local file and logs `Overwriting ...` with `:verbose`;
  with `:protect_local` it logs `Skipping ...: newer than the remote copy` instead.
* A download whose size disagrees with the listing logs a warning and keeps the
  file.
* A failed remote listing creates nothing locally; an empty listing for a
  missing directory pulls as an empty local directory.
* A file where the server needs a directory is logged as `exists but is not a
  directory`; the push fails or records the error under `:skip_errors`.
* One instance is not thread-safe; use one per thread. There is no single-file
  or subtree API: both methods work on whole trees.

## Development

Run `bin/setup`, then `rake` for tests and RuboCop (`rake test` and `rake
rubocop` separately); `bin/console` opens a prompt with the library loaded.

### Type checking

The gem ships RBS signatures in `sig/ftpsync.rbs`. `rake steep` checks `lib/`
against them and `rake rbs` validates them; both need Ruby 3.3 or newer, while
the library still supports Ruby 2.6. CI runs them in the `types` job on Ruby 4.0.
The signatures are not exhaustive: option values are `untyped`.

### Integration tests (requires Docker)

`rake test:integration` runs against vsftpd
([garethflowers/ftp-server](https://garethflowers.dev/docker-ftp-server/)) on
`127.0.0.1:2121` (control) and `127.0.0.1:40000-40009` (passive data). It skips
without Docker, or fails when `FTPSYNC_REQUIRE_DOCKER=true` is set, and recreates
the container each run. Set `FTPSYNC_TEST_USER`, `FTPSYNC_TEST_PASS` and
`FTPSYNC_TEST_FTP_PORT` to override the credentials and control port.

Run `bundle exec rake install` to install locally. To release, update
`version.rb`, then run `bundle exec rake release`; it tags the version, pushes
commits and tags, and pushes the `.gem` to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome at
https://github.com/quintasan/ftpsync. Contributors are expected to follow the
[Contributor Covenant](https://www.contributor-covenant.org) code of conduct.

## License

The gem is available as open source under the terms of the
[MIT License](http://opensource.org/licenses/MIT). It is a stripped down version
of [orlando/ftp_sync](https://github.com/orlando/ftp_sync).
