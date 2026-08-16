# FtpSync

[![CI](https://github.com/Quintasan/ftpsync/actions/workflows/ci.yml/badge.svg)](https://github.com/Quintasan/ftpsync/actions/workflows/ci.yml)

A simple library for synchronizing from/to FTP servers.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'ftpsync'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install ftpsync

## Usage

```ruby
example = FtpSync::Simple.new "ftp.example.com", "username", "password"
example.pull_dir('remotepath', 'localpath')
```

### Options

`FtpSync::Simple#new` accepts an options hash:

| Option     | Default | Description                        |
|------------|---------|------------------------------------|
| `:port`    | `21`    | FTP port to connect to             |
| `:passive` | `false` | Use passive mode                   |
| `:verbose` | `false` | Log progress to stderr             |

`FtpSync::Simple#pull_dir` accepts an options hash:

| Option         | Description                                                |
|----------------|------------------------------------------------------------|
| `:since`       | Skip files that already exist locally and are up to date   |
| `:skip_errors` | Rescue `Net::FTPPermError` and continue instead of raising |

> **Note:** `:since` compares size and the mtime reported by the server's
> `LIST` output, which usually has minute precision. A remote file of the
> same size that was modified within the same minute as the local copy may
> therefore be skipped.

Passing a block to `pull_dir` invokes it with the local path of each
downloaded file:

```ruby
example.pull_dir('remotepath', 'localpath', since: true) do |file|
  process(file)
end
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake` to run the tests and RuboCop (or `rake test` / `rake rubocop` individually). You can also run `bin/console` for an interactive prompt that will allow you to experiment.

### Integration tests (requires Docker)

The integration suite runs against a real FTP server
([garethflowers/ftp-server](https://garethflowers.dev/docker-ftp-server/),
vsftpd) in a Docker container:

    $ rake test:integration

The container listens on `127.0.0.1:2121` (control) and
`127.0.0.1:40000-40009` (passive data). The tests are skipped automatically
if Docker is not available, and the container is created and removed for
each run. Override the credentials and control port with the
`FTPSYNC_TEST_USER`, `FTPSYNC_TEST_PASS` and `FTPSYNC_TEST_FTP_PORT`
environment variables.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/quintasan/ftpsync. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [Contributor Covenant](https://www.contributor-covenant.org) code of conduct.

## License

The gem is available as open source under the terms of the [MIT License](http://opensource.org/licenses/MIT).

## Credits

This gem is a basically stripped down version of [orlando/ftp_sync](https://github.com/orlando/ftp_sync) which I couldn't get to work.