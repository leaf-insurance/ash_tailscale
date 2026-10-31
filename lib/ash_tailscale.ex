defmodule AshTailscale do
  @moduledoc """
  Builds transient Ash actors from Tailscale Serve header assertions.

  Start with the [LiveView setup guide](live_view.html) for an existing Phoenix
  application. `AshTailscale.Plug` handles ordinary HTTP routes after session/CSRF
  protection. The library supplies `AshTailscale.User` and its domain; no accounts
  table or session identity is needed. Capabilities are opaque consumer-policy data.

  These lower-level functions parse assertions, not credentials: they do not
  inspect sockets or establish trust. Require private Unix ingress from trusted
  Serve/host processes. Never persist an actor as fresh authority for later work;
  connected LiveView actors retain their original logical-transport snapshot.
  """

  @typedoc "Plug-style header pairs; assertion names are case-insensitive."
  @type headers :: [{String.t(), String.t()}]

  @typedoc "A decoded JSON value; the library imposes no nested capability schema."
  @type json_value ::
          nil
          | boolean()
          | number()
          | String.t()
          | [json_value()]
          | %{optional(String.t()) => json_value()}

  @typedoc "The complete decoded capability object forwarded for one request."
  @type capabilities :: %{optional(String.t()) => json_value()}

  @doc """
  Parses headers into a fresh actor, or returns `{:error, :invalid_headers}`.

  Login is required and preserved as supplied. Missing capability headers produce
  an empty map; present capability JSON must be an object. UTF-8 RFC2047 Q/B
  decoding and byte limits apply. Optional display decoding failures become nil,
  but byte-limit violations reject the assertion.

  This is **not credential validation**. Never pass browser parameters here or
  expose it as a public sign-in action; use the plug at the supported boundary.

      iex> {:ok, actor} = AshTailscale.from_headers([{"tailscale-user-login", "alice@example.com"}])
      iex> {actor.login, actor.capabilities}
      {"alice@example.com", %{}}
      iex> AshTailscale.from_headers([])
      {:error, :invalid_headers}
  """
  @spec from_headers(headers()) :: {:ok, AshTailscale.User.t()} | {:error, :invalid_headers}
  def from_headers(headers) do
    with {:ok, attrs} <- AshTailscale.Headers.parse(headers) do
      {:ok,
       AshTailscale.User
       |> struct!(attrs)
       |> Ash.Resource.set_metadata(%{ash_tailscale: :request_headers})}
    end
  end

  @doc """
  Recognizes the library actor shape and provenance marker.

  Returns false for nil/unrelated/unmarked actors. The marker is not cryptographic
  proof, a freshness check, or protection against trusted application code forging
  or restoring a serialized struct.

      iex> AshTailscale.actor?(nil)
      false
      iex> AshTailscale.actor?(AshTailscale.test_actor!("alice@example.com"))
      true
  """
  @spec actor?(term()) :: boolean()
  def actor?(%AshTailscale.User{login: login, capabilities: caps} = actor)
      when is_binary(login) and byte_size(login) > 0 and is_map(caps) do
    Ash.Resource.get_metadata(actor, :ash_tailscale) == :request_headers
  end

  def actor?(_), do: false

  @doc """
  Constructs an actor for policy tests without a proxy.

  Accepts a login and JSON capability map (default `%{}`), round-tripping through
  the same parser. Raises on invalid input or byte-limit violations. This helper
  does not establish transport/proxy trust and is **not a production bypass**.

      iex> caps = %{"example.com/cap/reports" => [%{"actions" => ["read"]}]}
      iex> actor = AshTailscale.test_actor!("alice@example.com", caps)
      iex> actor.capabilities == caps
      true
  """
  @spec test_actor!(String.t(), capabilities()) :: AshTailscale.User.t()
  def test_actor!(login, capabilities \\ %{}) do
    {:ok, actor} =
      from_headers([
        {"tailscale-user-login", login},
        {"tailscale-app-capabilities", Jason.encode!(capabilities)}
      ])

    actor
  end
end
