defmodule AshTailscale.MixProject do
  use Mix.Project

  def project do
    [
      app: :ash_tailscale,
      version: "0.1.0",
      name: "AshTailscale",
      description:
        "Transient Tailscale Serve actors and capability checks for Ash browser applications.",
      source_url: "https://github.com/leaf-insurance/ash_tailscale",
      homepage_url: "https://github.com/leaf-insurance/ash_tailscale",
      package: [
        files: ~w(lib config examples docs mix.exs README.md LICENSE .formatter.exs),
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/leaf-insurance/ash_tailscale"}
      ],
      docs: [
        main: "readme",
        source_ref: "main",
        extras: ["README.md", "docs/deployment.md"]
      ],
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths:
        if(Mix.env() == :test, do: ["lib", "test/support", "examples"], else: ["lib"]),
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [
      {:ash, "~> 3.37.2"},
      {:ash_authentication, "~> 4.15.0"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.18"},
      {:phoenix, "~> 1.8.16", only: [:dev, :test]},
      {:phoenix_html, "~> 4.3.0", only: [:dev, :test]},
      {:phoenix_live_view, "~> 1.2.13", only: [:dev, :test]},
      {:bandit, "~> 1.14.1", only: :test},
      {:simple_sat, "~> 0.1.4", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ash_credo, "== 0.18.0", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40.4", only: :dev, runtime: false},
      {:sourceror, "~> 1.13", only: [:dev, :test], runtime: false}
    ]
  end
end
