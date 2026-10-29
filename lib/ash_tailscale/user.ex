defmodule AshTailscale.User do
  @moduledoc """
  The library-owned, non-persisted Ash actor for a single request.

  Obtain one through `AshTailscale.Plug`, the trusted-server builder
  `AshTailscale.from_headers/1`, or `AshTailscale.test_actor!/2` in policy tests.
  Applications do not configure this resource or supply an Accounts domain.

  Fields:
  * `login` — required string primary key, preserved rather than normalized.
    It can change or be reassigned; it is not an immutable ownership identifier.
  * `name`, `profile_pic` — optional display strings or nil. Escape display
    data and do not fetch profile URLs server-side; neither grants authority.
  * `capabilities` — the whole decoded JSON object, with nested values/null intact.

  Never store this actor in sessions, tokens, caches or job arguments. A subject
  cannot reload current authority; the library's subject-read action always fails.
  Provenance metadata is a trusted-code convention, not a signed credential.
  """
  use Ash.Resource,
    domain: AshTailscale.Domain,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshAuthentication, AshTailscale.Strategy]

  authentication do
    strategies do
      tailscale :tailscale
    end
  end

  attributes do
    attribute :login, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :name, :string, public?: true
    attribute :profile_pic, :string, public?: true
    attribute :capabilities, :map, allow_nil?: false, default: %{}, public?: true
  end

  actions do
    read :get_by_subject do
      get? true
      argument :subject, :string
      prepare AshTailscale.NoSubjectReload
    end
  end
end

defmodule AshTailscale.NoSubjectReload do
  @moduledoc false
  use Ash.Resource.Preparation

  @impl true
  def prepare(query, _, _) do
    Ash.Query.add_error(query, "Tailscale authentication requires current request headers")
  end
end
