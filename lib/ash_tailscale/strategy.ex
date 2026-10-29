defmodule AshTailscale.Strategy do
  @moduledoc """
  Library-owned, route-less and token-free Ash Authentication integration.

  This strategy is already attached to `AshTailscale.User`. Consumers use
  `AshTailscale.Plug`; they should not attach this extension to their own users.
  This is not a general custom-user DSL API. Its sole server-side sign-in operation
  uses internal adapter input, never public request parameters. No routes, tokens
  or session identity are provided.
  """
  use AshAuthentication.Strategy.Custom,
    entity: %Spark.Dsl.Entity{
      name: :tailscale,
      target: __MODULE__,
      args: [{:optional, :name, :tailscale}],
      schema: [name: [type: :atom, default: :tailscale]]
    }

  defstruct name: :tailscale, resource: nil, __spark_metadata__: nil
end

defimpl AshAuthentication.Strategy, for: AshTailscale.Strategy do
  @impl true
  def name(strategy), do: strategy.name

  @impl true
  def phases(_), do: []

  @impl true
  def routes(_), do: []

  @impl true
  def actions(_), do: [:sign_in]

  @impl true
  def tokens_required?(_), do: false

  @impl true
  def method_for_phase(_, _), do: :get

  @impl true
  def plug(_, _, conn), do: conn

  @impl true
  def action(_, :sign_in, %{assertion: %AshTailscale.Assertion{headers: headers}}, []) do
    AshTailscale.from_headers(headers)
  end

  def action(_, _, _, _), do: {:error, :invalid_assertion}
end
