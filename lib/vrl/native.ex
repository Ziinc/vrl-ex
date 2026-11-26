defmodule VRL.Native do
  @moduledoc false

  version = Mix.Project.config()[:version]

  use RustlerPrecompiled,
    otp_app: :vrl,
    crate: "vrl_nif",
    base_url: "https://github.com/Ziinc/vrl-ex/releases/download/v#{version}",
    force_build: System.get_env("VRL_BUILD") in ["1", "true"],
    version: version,
    targets: ~w(
      aarch64-apple-darwin
      aarch64-unknown-linux-gnu
      aarch64-unknown-linux-musl
      x86_64-apple-darwin
      x86_64-pc-windows-gnu
      x86_64-pc-windows-msvc
      x86_64-unknown-linux-gnu
      x86_64-unknown-linux-musl
    )

  def compile(_source, _deny_functions), do: :erlang.nif_error(:nif_not_loaded)

  def run(_program, _event, _timeout_ms, _metadata, _strip_structs),
    do: :erlang.nif_error(:nif_not_loaded)
end
