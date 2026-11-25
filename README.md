# VRL

Elixir bindings for [Vector Remap Language](https://vrl.dev), built with
[Rustler](https://github.com/rusterlium/rustler). Precompiled NIFs are
downloaded via [RustlerPrecompiled](https://github.com/philss/rustler_precompiled),
so Rust is not required to use the library.

## Installation

```elixir
def deps do
  [{:vrl, "~> 0.1"}]
end
```

To build the NIF from source, add `{:rustler, ">= 0.0.0"}` to your deps and set `VRL_BUILD=1`.

## Usage

```elixir
{:ok, program} = VRL.compile(~S"""
.message = upcase!(.message)
.processed_at = now()
""")

{:ok, %VRL.Result{event: event}} = VRL.run(program, %{"message" => "hello"}, timeout: 1_000)
event["message"]
#=> "HELLO"
```

Compile once and reuse the program across processes. See `VRL` docs for the
type mapping between Elixir terms and VRL values.

## Releasing

Requires a `HEX_API_KEY` repository secret.

1. Bump `@version` in `mix.exs`, update `CHANGELOG.md` and merge to `main`.
2. Tag and push: `git tag v0.1.0 && git push origin v0.1.0`.

The Release workflow builds the NIFs, attaches them and the checksum file to the
GitHub release, commits the checksum file to `main`, and publishes to Hex.
