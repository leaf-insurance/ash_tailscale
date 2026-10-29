defmodule AshTailscale.TestDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshTailscale.FilteredRead
  end
end

defmodule AshTailscale.FilteredRead do
  @moduledoc false
  use Ash.Resource,
    domain: AshTailscale.TestDomain,
    data_layer: Ash.DataLayer.Simple,
    authorizers: [Ash.Policy.Authorizer]

  attributes do
    attribute :title, :string, primary_key?: true, allow_nil?: false
  end

  actions do
    defaults [:read]
  end

  policies do
    policy action_type(:read) do
      authorize_if {AshTailscale.CapabilityCheck,
                    predicate: {AshTailscale.Example.Capabilities, :allowed?, ["read"]}}

      # An independent consumer policy can still authorize rows when the check denies.
      authorize_if expr(title == "public")
    end
  end
end
