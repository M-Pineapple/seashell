# Changelog

Notable changes to SeaShell are listed here. Earlier releases are on the [GitHub Releases](https://github.com/M-Pineapple/seashell/releases) page.

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
