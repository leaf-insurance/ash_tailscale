defmodule AshTailscale.LiveViewTest do
  use ExUnit.Case, async: true
  alias AshTailscale.Example.Report
  alias AshTailscale.LiveView
  alias AshTailscale.LiveView.Endpoint
  alias AshTailscale.Test.LiveEndpoint
  alias AshTailscale.Test.LiveRouter
  alias AshTailscale.Test.UnbridgedEndpoint
  alias Phoenix.LiveView.Socket

  test "bridge strips the entire reserved namespace, preserves canonical duplicates and values" do
    headers = [
      {"x-ash-tailscale-tailscale-user-login", "forged"},
      {"x-ash-tailscale-unknown", "forged"},
      {"tailscale-user-login", "alice"},
      {"tailscale-user-login", "bob"},
      {"tailscale-app-capabilities", "{}"},
      {"x-other", "preserved"}
    ]

    conn = conn(headers) |> Endpoint.bridge()
    refute List.keymember?(conn.req_headers, "x-ash-tailscale-unknown", 0)
    assert {"x-other", "preserved"} in conn.req_headers

    assert Endpoint.canonical_headers(conn.req_headers) == [
             {"tailscale-user-login", "alice"},
             {"tailscale-user-login", "bob"},
             {"tailscale-app-capabilities", "{}"}
           ]

    assert :error == LiveView.connect(%{endpoint: LiveEndpoint}, info(conn))
  end

  test "invalid peers are independently rejected and stripped, ignoring remote_ip" do
    for peer <- [
          %{},
          %{address: nil},
          %{address: {127, 0, 0, 1}},
          %{address: {0, 0, 0, 0, 0, 0, 0, 1}}
        ] do
      conn =
        [{"tailscale-user-login", "alice"}, {"x-ash-tailscale-tailscale-user-login", "admin"}]
        |> conn()
        |> Plug.Test.put_peer_data(peer)
        |> Map.put(:remote_ip, {:local, "fake"})
        |> Endpoint.bridge()

      assert conn.halted
      assert conn.status == 403
      assert conn.resp_body == "Forbidden"
      assert Endpoint.canonical_headers(conn.req_headers) == []
      assert :error == LiveView.connect(%{endpoint: LiveEndpoint}, info(conn))

      forged_info = %{info(conn) | x_headers: [{"x-ash-tailscale-tailscale-user-login", "admin"}]}
      assert :error == LiveView.connect(%{endpoint: LiveEndpoint}, forged_info)
    end
  end

  test "connected validation requires integration, session, peer and valid canonical assertion" do
    conn = conn([{"tailscale-user-login", "alice"}]) |> Endpoint.bridge()
    info = info(conn)
    socket = %{endpoint: LiveEndpoint}
    assert {:ok, ^socket} = LiveView.connect(socket, info)

    for bad <- [
          Map.delete(info, :session),
          %{info | session: nil},
          Map.delete(info, :peer_data),
          %{info | x_headers: []},
          %{info | x_headers: nil}
        ] do
      assert LiveView.connect(socket, bad) == :error
    end

    assert LiveView.connect(%{endpoint: __MODULE__}, info) == :error
    assert LiveView.connect(socket, %{info | peer_data: nil}) == :error
  end

  test "root mount replaces stale assigns, ignores params/session and preserves opaque caps" do
    caps = %{"arbitrary" => [nil, %{"nested" => [1, false]}], "other" => nil}

    conn =
      conn([{"tailscale-user-login", "bob"}, {"tailscale-app-capabilities", Jason.encode!(caps)}])
      |> Endpoint.bridge()

    for connect_info <- [conn, info(conn)] do
      socket = socket(connect_info)

      assert {:cont, socket} =
               LiveView.on_mount(
                 "/failure",
                 %{"login" => "params"},
                 %{"login" => "session"},
                 socket
               )

      assert socket.assigns.current_user.login == "bob"
      assert socket.assigns.current_user.capabilities == caps
    end
  end

  test "failure clears prior actor; nested/sticky roots cannot fall back to parent/session" do
    conn = conn([]) |> Endpoint.bridge()
    socket = socket(conn)

    assert {:halt, failed} =
             LiveView.on_mount("/failure", %{}, %{"current_user" => "admin"}, socket)

    assert failed.assigns.current_user == nil
    assert failed.redirected == {:redirect, %{to: "/failure", status: 302}}

    valid = conn([{"tailscale-user-login", "alice"}]) |> Endpoint.bridge() |> socket()

    for unsupported <- [
          %{valid | parent_pid: self()},
          %{valid | sticky?: true},
          %{valid | router: nil}
        ] do
      assert {:error, failed} = LiveView.assign_actor(unsupported)
      assert failed.assigns.current_user == nil
    end
  end

  test "unbridged disconnected mount raises configuration error and cannot reuse stale actor" do
    socket = conn([{"x-ash-tailscale-tailscale-user-login", "forged"}]) |> socket()
    refute Phoenix.LiveView.connected?(socket)
    assert_missing_bridge(socket)
  end

  test "unbridged connected mount independently rejects despite otherwise valid connect info" do
    socket = conn([{"tailscale-user-login", "bob"}]) |> Endpoint.bridge() |> info() |> socket()
    assert Phoenix.LiveView.connected?(socket)
    assert_missing_bridge(socket)
  end

  defp assert_missing_bridge(socket) do
    actor =
      AshTailscale.test_actor!("stale", %{"example.com/cap/reports" => [%{"actions" => ["read"]}]})

    socket = %{socket | endpoint: UnbridgedEndpoint}
    socket = Phoenix.Component.assign(socket, :current_user, actor)
    assert {:ok, _reports} = Ash.read(Report, actor: socket.assigns.current_user)

    # Exercise mount directly, independently of the socket connect/2 gate.
    assert_raise ArgumentError, ~r/requires `use AshTailscale.LiveView.Endpoint`/, fn ->
      LiveView.on_mount("/failure", %{}, %{"current_user" => "admin"}, socket)
    end

    assert {:error, cleared} = LiveView.assign_actor(socket)
    assert cleared.assigns.current_user == nil

    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.read(Report, actor: cleared.assigns.current_user)
  end

  defp conn(headers) do
    Plug.Test.conn(:get, "/")
    |> Plug.Test.put_peer_data(%{address: {:local, ""}, port: 0, ssl_cert: nil})
    |> Map.put(:req_headers, headers)
  end

  defp info(conn),
    do: %{peer_data: Plug.Conn.get_peer_data(conn), x_headers: conn.req_headers, session: %{}}

  defp socket(connect_info) do
    %Socket{
      endpoint: LiveEndpoint,
      router: LiveRouter,
      transport_pid: if(is_struct(connect_info, Plug.Conn), do: nil, else: self()),
      assigns: %{__changed__: %{}, current_user: AshTailscale.test_actor!("stale")},
      private: %{connect_info: connect_info}
    }
  end
end
