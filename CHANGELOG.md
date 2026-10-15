# Changelog

Notable changes to SeaShell are listed here. Earlier releases are on the [GitHub Releases](https://github.com/M-Pineapple/seashell/releases) page.

## [Unreleased]

### Security

- Command scripts and captured output now go to a private per-user scratch folder (owner-only `0700`) instead of the shared `/tmp`. Scripts are written owner-only and run with `umask 077`.
- `execute_pipeline`, `execute_with_streaming` and the working-directory form of `execute_command` now apply the blocked-commands policy, and the check is less sensitive to spacing and flag order. The list is a guard against mistakes, not a security boundary; the README now says so.

Details are in a private advisory and will be published after release.

## [2.2.4] - 2026-10-14

### Documentation

- README now states up front that SeaShell is macOS-only.

## [2.2.3] - 2026-10-13

Wave secret tools now require a reason before they run, and `wave_secret_get` withholds the plaintext value by default.

If you relied on reading secret values through the MCP server, set `SEASHELL_ALLOW_SECRET_READ=1` in the SeaShell server environment. Please update to this release.

### Changed

- Secret tools require `approved=true` and a non-empty `reason`.
- `wave_secret_get` returns the plaintext value only when `SEASHELL_ALLOW_SECRET_READ=1` is set in the server environment.

[2.2.4]: https://github.com/M-Pineapple/seashell/compare/v2.2.3...v2.2.4
[2.2.3]: https://github.com/M-Pineapple/seashell/compare/v2.2.2...v2.2.3
