defmodule VRL.MixProject do
  use Mix.Project

  @version "0.1.0-dev"
  @source_url "https://github.com/Ziinc/vrl-ex"

  def project do
    [
      app: :vrl,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Elixir bindings for Vector Remap Language (VRL)",
      source_url: @source_url,
      package: package(),
      docs: [main: "VRL", source_ref: "v#{@version}"]
    ]
  end

  def application, do: []

  defp deps do
    [
      {:rustler_precompiled, "~> 0.10"},
      {:rustler, "~> 0.38", optional: true},
      {:stream_data, "~> 1.4", only: :test},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MPL-2.0"],
      links: %{"GitHub" => @source_url, "VRL" => "https://vrl.dev"},
      files:
        ~w(lib native/vrl_nif/.cargo native/vrl_nif/src native/vrl_nif/Cargo.* mix.exs README.md checksum-*.exs)
    ]
  end
end
