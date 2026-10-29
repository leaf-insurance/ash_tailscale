defmodule AshTailscale.Strategy do
  @moduledoc """
  Route-less, token-free Ash Authentication strategy used by the library resource.
  Its only operation is server-side sign-in with an internal header assertion.
  """
  defstruct name: :tailscale, resource: nil, __spark_metadata__: nil

  use AshAuthentication.Strategy.Custom,
    entity: %Spark.Dsl.Entity{
      name: :tailscale,
      target: __MODULE__,
      args: [{:optional, :name, :tailscale}],
      schema: [name: [type: :atom, default: :tailscale]]
    }
end

defimpl AshAuthentication.Strategy, for: AshTailscale.Strategy do
  def name(strategy), do: strategy.name
  def phases(_), do: []
  def routes(_), do: []
  def actions(_), do: [:sign_in]
  def tokens_required?(_), do: false
  def method_for_phase(_, _), do: :get
  def plug(_, _, conn), do: conn

  def action(_, :sign_in, %{assertion: %AshTailscale.Assertion{headers: headers}}, []) do
    AshTailscale.from_headers(headers)
  end

  def action(_, _, _, _), do: {:error, :invalid_assertion}
end
