defmodule AshTailscale.CapabilityCheck do
  @moduledoc """
  A thin Ash policy check calling a consumer MFA with the entire capability map
  prepended to its argument list. Only literal true authorizes.

      authorize_if {AshTailscale.CapabilityCheck, predicate: {MyApp.Caps, :can_read?, []}}

  Nil/unrelated actors and predicate exceptions, throws, exits or non-booleans
  deny access. The predicate receives the **entire** decoded JSON object, followed
  by the MFA's extra arguments; its nested schema and scope semantics are yours.

  Use with `Ash.Policy.Authorizer` on application resources. This is an action-level
  check, not a row-level ownership filter. A sole denied check returns a forbidden
  error; independent row-filter policies may instead yield empty read results.
  Do not persist an actor/capability snapshot to reuse as later authority.
  """
  use Ash.Policy.SimpleCheck

  @typedoc "Consumer callback; the capability map is prepended to the extra arguments."
  @type predicate :: {module(), atom(), [term()]}

  @doc "Validates the predicate MFA option; returns {:ok, opts} or an error message."
  @impl true
  @spec init(keyword()) :: {:ok, keyword()} | {:error, String.t()}
  def init(opts) do
    case Keyword.get(opts, :predicate) do
      {module, function, args} when is_atom(module) and is_atom(function) and is_list(args) ->
        {:ok, opts}

      _ ->
        {:error, "expected predicate: {Module, :function, extra_args}"}
    end
  end

  @doc false
  @impl true
  def describe(_), do: "current Tailscale actor satisfies the capability predicate"

  @doc """
  Returns true only for a library actor whose consumer predicate returns true.

  `opts` must contain `predicate: {Module, :function, extra_args}`. Context is
  unused. Exceptions, throws, exits, missing functions and non-booleans deny.
  """
  @impl true
  @spec match?(term(), term(), keyword()) :: boolean()
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
