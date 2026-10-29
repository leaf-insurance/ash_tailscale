defmodule AshTailscale.Plug do
  @moduledoc """
  Required request authentication after fetch_session / protect_from_forgery.
  Only supported behind Serve's HTTP proxy to a private Unix socket.
  No identity is read from or written to the session.
  """
  @behaviour Plug
  import Plug.Conn

  def init([]), do: []
  def init(_), do: raise(ArgumentError, "AshTailscale.Plug has no options")

  def call(conn, []) do
    # Also clear the deprecated Ash actor assign so it cannot override the new actor.
    conn =
      conn
      |> assign(:current_user, nil)
      |> Map.update!(:assigns, &Map.delete(&1, :actor))
      |> Ash.PlugHelpers.set_actor(nil)

    # The adapter's peer address enforces the fixed transport, not proxy identity.
    # remote_ip and forwarded headers may have been rewritten by earlier plugs.
    with true <- unix_peer?(conn),
         {:ok, actor} <- sign_in(conn.req_headers) do
      conn |> assign(:current_user, actor) |> Ash.PlugHelpers.set_actor(actor)
    else
      _ -> conn |> send_resp(401, "Unauthorized") |> halt()
    end
  end

  defp unix_peer?(conn) do
    match?(%{address: {:local, _}}, get_peer_data(conn))
  rescue
    _ -> false
  end

  defp sign_in(headers) do
    strategy = AshAuthentication.Info.strategy!(AshTailscale.User, :tailscale)
    assertion = %AshTailscale.Assertion{headers: headers}
    AshAuthentication.Strategy.action(strategy, :sign_in, %{assertion: assertion}, [])
  end
end
