# Changelog

## 0.1.0

Initial release.

- `VRL.compile/1` and `VRL.run/3` with the VRL standard library (except network functions)
- Elixir ↔ VRL value conversion, including `DateTime` ↔ timestamp
- `:timeout` (default 5s) and `:strip_structs` options for `VRL.run/3`
- Precompiled NIFs for macOS, Linux (gnu/musl) and Windows on x86_64 and aarch64
