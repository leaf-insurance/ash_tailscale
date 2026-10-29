defmodule AshTailscale.Example.Capabilities do
  @moduledoc false
  # This schema belongs only to the example consumer, not to AshTailscale.
  @spec allowed?(AshTailscale.capabilities(), String.t()) :: boolean()
  def allowed?(caps, action) do
    case caps["example.com/cap/reports"] do
      entries when is_list(entries) ->
        Enum.any?(entries, fn
          %{"actions" => actions} when is_list(actions) -> action in actions
          _ -> false
        end)

      _ ->
        false
    end
  end
end

defmodule AshTailscale.Example.Reports do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshTailscale.Example.Report
  end
end

defmodule AshTailscale.Example.Report do
  @moduledoc false
  use Ash.Resource,
    domain: AshTailscale.Example.Reports,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer]

  # Example application data only; never an identity store.
  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, public?: true, allow_nil?: false
  end

  actions do
    defaults [:read, :destroy, create: [:title], update: [:title]]
  end

  policies do
    policy action_type(:read) do
      authorize_if {AshTailscale.CapabilityCheck,
                    predicate: {AshTailscale.Example.Capabilities, :allowed?, ["read"]}}
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if {AshTailscale.CapabilityCheck,
                    predicate: {AshTailscale.Example.Capabilities, :allowed?, ["write"]}}
    end
  end
end
