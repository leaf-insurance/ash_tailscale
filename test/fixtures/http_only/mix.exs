defmodule AshTailscale.HttpOnlyFixture.MixProject do
  @moduledoc false
  use Mix.Project

  @spec project() :: keyword()
  def project do
    [
      app: :http_only_fixture,
      version: "0.0.0",
      elixir: "~> 1.18",
      deps: [{:ash_tailscale, path: System.fetch_env!("ASH_TAILSCALE_PATH")}]
    ]
  end

  @spec application() :: keyword()
  def application, do: [extra_applications: [:logger]]
end
