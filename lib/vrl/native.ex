defmodule VRL.Native do
  @moduledoc false

  version = Mix.Project.config()[:version]

  use RustlerPrecompiled,
    otp_app: :vrl,
    crate: "vrl_nif",
    base_url: "https://github.com/Ziinc/vrl-ex/releases/download/v#{version}",
    force_build: System.get_env("VRL_BUILD") in ["1", "true"],
    version: version

  def compile(_source), do: :erlang.nif_error(:nif_not_loaded)
  def run(_program, _event), do: :erlang.nif_error(:nif_not_loaded)
end
