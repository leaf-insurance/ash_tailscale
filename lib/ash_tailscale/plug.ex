defmodule AshTailscale.Plug do
  @moduledoc """
  Required browser-request authentication behind Serve's HTTP Unix-socket proxy.

  Place after Phoenix's `:fetch_session` and `:protect_from_forgery` in every
  protected HTML/browser-JSON pipeline. It has no options and never reads or writes
  session identity; the session holds only CSRF/UI state.

  Only an actual adapter peer address `{:local, _}` is accepted, not `remote_ip`
  or forwarded headers. Missing/invalid assertions or non-Unix peers clear stale
  actors and halt with generic HTTP 401. A Unix peer does not prove the caller is
  Serve: private socket permissions and a trusted host remain required.

  Success sets `conn.assigns.current_user` and `Ash.PlugHelpers.get_actor/1`.
  Pass that actor explicitly into each Ash action; connection assignment alone
  does not authorize Ash calls. In-process tests must set test-adapter Unix peer
  data using `Plug.Test.put_peer_data/2`; this does not test real isolation.
  """
  @behaviour Plug
  import Plug.Conn

  @doc "Accepts only an empty option list; other options raise ArgumentError."
  @impl true
  @spec init(keyword()) :: []
  def init([]), do: []
  def init(_), do: raise(ArgumentError, "AshTailscale.Plug has no options")

  @doc "Builds and assigns a request actor, or sends HTTP 401 and halts the connection."
  @impl true
  @spec call(Plug.Conn.t(), []) :: Plug.Conn.t()
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
