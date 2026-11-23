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

{:ok, _value, event} = VRL.run(program, %{"message" => "hello"})
event["message"]
#=> "HELLO"
```

Compile once and reuse the program across processes. See `VRL` docs for the
type mapping between Elixir terms and VRL values.

## Releasing

1. Bump `@version` in `mix.exs`, commit, then tag and push: `git tag v0.1.0 && git push origin main --tags`.
2. Wait for the "Build precompiled NIFs" workflow to attach all NIFs to the GitHub release.
3. Generate the checksum file: `VRL_BUILD=1 mix rustler_precompiled.download VRL.Native --all --print`.
4. Publish: `mix hex.publish`.
