defmodule AshTailscale.CapabilityCheck do
  @moduledoc """
  A thin Ash policy check calling a consumer MFA with the entire capability map
  prepended to its argument list. Only literal true authorizes.

      authorize_if {AshTailscale.CapabilityCheck, predicate: {MyApp.Caps, :can_read?, []}}

  Nil/unrelated actors and predicate exceptions, throws, exits or non-booleans
  deny access. This is an action-level check, not a row-level ownership filter.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def init(opts) do
    case Keyword.get(opts, :predicate) do
      {module, function, args} when is_atom(module) and is_atom(function) and is_list(args) ->
        {:ok, opts}

      _ ->
        {:error, "expected predicate: {Module, :function, extra_args}"}
    end
  end

  @impl true
  def describe(_), do: "current Tailscale actor satisfies the capability predicate"

  @impl true
  def match?(actor, _context, opts) do
    if AshTailscale.actor?(actor) do
      {module, function, args} = Keyword.fetch!(opts, :predicate)
      apply(module, function, [actor.capabilities | args]) === true
    else
      false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end
end
