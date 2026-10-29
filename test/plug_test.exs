defmodule AshTailscale.PlugTest do
  use ExUnit.Case, async: true
  import Plug.Conn

  test "builds a fresh actor for each request, replaces other actors, ignores session identity" do
    previous = AshTailscale.test_actor!("old", %{"write" => true})

    conn =
      Plug.Test.conn(:get, "/")
      |> Plug.Test.put_peer_data(%{address: {:local, ""}, port: 0})
      |> Plug.Test.init_test_session(%{current_user: previous})
      |> assign(:current_user, previous)
      |> assign(:actor, previous)
      |> Ash.PlugHelpers.set_actor(previous)
      |> put_req_header("tailscale-user-login", "alice")
      |> put_req_header("tailscale-app-capabilities", "{\"one\":null}")
      |> AshTailscale.Plug.call([])

    actor = conn.assigns.current_user
    assert actor.login == "alice"
    assert actor.capabilities == %{"one" => nil}
    assert Ash.PlugHelpers.get_actor(conn) == actor

    next =
      conn
      |> delete_req_header("tailscale-app-capabilities")
      |> AshTailscale.Plug.call([])

    assert next.assigns.current_user.login == "alice"
    assert next.assigns.current_user.capabilities == %{}
    assert actor.capabilities == %{"one" => nil}
    # This plug neither consumes nor writes session identity; consumers must not put it there.
    assert get_session(next, :current_user) == previous
  end

  test "missing and malformed assertions halt with generic 401 and clear stale actors" do
    previous = AshTailscale.test_actor!("old")

    for headers <- [
          [],
          [{"tailscale-user-login", "alice"}, {"tailscale-app-capabilities", "bad"}]
        ] do
      conn =
        Plug.Test.conn(:get, "/")
        |> Plug.Test.put_peer_data(%{address: {:local, ""}, port: 0})
        |> Map.put(:req_headers, headers)
        |> Plug.Test.init_test_session(%{current_user: previous})
        |> assign(:current_user, previous)
        |> assign(:actor, previous)
        |> Ash.PlugHelpers.set_actor(previous)
        |> AshTailscale.Plug.call([])

      assert conn.halted
      assert conn.status == 401
      assert conn.resp_body == "Unauthorized"
      assert conn.assigns.current_user == nil
      assert Ash.PlugHelpers.get_actor(conn) == nil
    end
  end

  test "only the adapter's Unix peer permits authentication, not remote_ip or forwarded headers" do
    previous = AshTailscale.test_actor!("old")

    for peer <- [
          nil,
          %{},
          %{address: nil},
          %{address: {127, 0, 0, 1}, port: 1234},
          %{address: {0, 0, 0, 0, 0, 0, 0, 1}, port: 1234}
        ],
        remote_ip <- [{:local, ""}, {127, 0, 0, 1}] do
      conn =
        Plug.Test.conn(:get, "/")
        |> Plug.Test.put_peer_data(peer)
        |> Map.put(:remote_ip, remote_ip)
        |> put_req_header("tailscale-user-login", "forged")
        |> put_req_header("x-forwarded-for", "127.0.0.1")
        |> put_req_header("x-forwarded-proto", "https")
        |> put_req_header("forwarded", "for=unix")
        |> assign(:current_user, previous)
        |> assign(:actor, previous)
        |> Ash.PlugHelpers.set_actor(previous)
        |> AshTailscale.Plug.call([])

      assert conn.halted
      assert conn.status == 401
      assert conn.resp_body == "Unauthorized"
      assert conn.assigns.current_user == nil
      assert Ash.PlugHelpers.get_actor(conn) == nil
    end

    missing = Plug.Test.conn(:get, "/") |> put_req_header("tailscale-user-login", "forged")
    {adapter, payload} = missing.adapter
    missing = %{missing | adapter: {adapter, Map.delete(payload, :peer_data)}}
    assert AshTailscale.Plug.call(missing, []).status == 401

    conn =
      Plug.Test.conn(:get, "/")
      |> Plug.Test.put_peer_data(%{address: {:local, ""}, port: 0})
      |> Map.put(:remote_ip, {203, 0, 113, 1})
      |> put_req_header("tailscale-user-login", "alice")
      |> AshTailscale.Plug.call([])

    refute conn.halted
    assert conn.assigns.current_user.login == "alice"
  end

  test "there are no trust, capability allowlist, or optional-auth options" do
    assert AshTailscale.Plug.init([]) == []
    assert_raise ArgumentError, fn -> AshTailscale.Plug.init(trusted_proxy: true) end
  end
end
