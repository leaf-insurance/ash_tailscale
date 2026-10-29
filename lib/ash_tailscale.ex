defmodule AshTailscale do
  @moduledoc """
  Request-scoped Tailscale actors. These functions parse assertions, not credentials:
  callers must establish the private Unix-socket / Serve HTTP proxy boundary.
  """

  @doc """
  Pure header-to-actor builder. Accepts a Plug-style list of header pairs.
  Never pass browser parameters here or expose this as a public sign-in action.
  """
  def from_headers(headers) do
    with {:ok, attrs} <- AshTailscale.Headers.parse(headers) do
      {:ok,
       AshTailscale.User
       |> struct!(attrs)
       |> Ash.Resource.set_metadata(%{ash_tailscale: :request_headers})}
    end
  end

  @doc "Whether an actor was built by this library. Not cryptographic proof or a freshness check."
  def actor?(%AshTailscale.User{login: login, capabilities: caps} = actor)
      when is_binary(login) and byte_size(login) > 0 and is_map(caps) do
    Ash.Resource.get_metadata(actor, :ash_tailscale) == :request_headers
  end

  def actor?(_), do: false

  @doc """
  Construct an actor for policy tests without a proxy. Do not use as a production
  authentication bypass. Capabilities are round-tripped through the same parser.
  """
  def test_actor!(login, capabilities \\ %{}) do
    {:ok, actor} =
      from_headers([
        {"tailscale-user-login", login},
        {"tailscale-app-capabilities", Jason.encode!(capabilities)}
      ])

    actor
  end
end
