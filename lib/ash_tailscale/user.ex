defmodule AshTailscale.User do
  @moduledoc """
  A non-persisted request actor. Login is a primary key, not an immutable ID.
  Never store this actor in sessions, tokens, caches, or job arguments.
  """
  use Ash.Resource,
    domain: AshTailscale.Domain,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshAuthentication, AshTailscale.Strategy]

  authentication do
    strategies do
      tailscale(:tailscale)
    end
  end

  attributes do
    attribute(:login, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:name, :string, public?: true)
    attribute(:profile_pic, :string, public?: true)
    attribute(:capabilities, :map, allow_nil?: false, default: %{}, public?: true)
  end

  actions do
    read :get_by_subject do
      get?(true)
      argument(:subject, :string)
      prepare(AshTailscale.NoSubjectReload)
    end
  end
end

defmodule AshTailscale.NoSubjectReload do
  @moduledoc false
  use Ash.Resource.Preparation

  def prepare(query, _, _) do
    Ash.Query.add_error(query, "Tailscale authentication requires current request headers")
  end
end
