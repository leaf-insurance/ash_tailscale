defmodule AshTailscale.StandardLiveViewTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias AshTailscale.Example
  alias AshTailscale.Test.LiveEndpoint
  alias AshTailscale.Test.UnbridgedEndpoint

  @endpoint LiveEndpoint
  @moduletag capture_log: true
  @caps %{
    "example.com/cap/reports" => [%{"actions" => ["read", "write"]}],
    "opaque" => [nil, %{"nested" => false}]
  }

  setup do
    previous = Application.get_env(:ash_tailscale, @endpoint)

    config =
      Example.config(
        "unused-test-socket",
        "app.example.test",
        String.duplicate("standard-lv-test-", 5)
      )

    Application.put_env(:ash_tailscale, @endpoint, Keyword.put(config, :server, false))
    start_supervised!({Phoenix.PubSub, name: Example.PubSub})
    start_supervised!(@endpoint)
    on_exit(fn -> restore(@endpoint, previous) end)
    %{conn: tailscale_conn(build_conn()), config: config}
  end

  test "ordinary live/2 mounts the current actor and enforces root/component policies", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, "/")
    assert html =~ "alice@example.test"
    refute html =~ "stale-admin"
    render_hook(view, "snapshot", %{})
    assert_reply view, %{login: "alice@example.test", capabilities: @caps, read: true}
    render_click(element(view, "button[phx-click=snapshot]"))
    assert_reply view, %{login: "alice@example.test", capabilities: @caps, read: true}
    render_hook(view, "write", %{})
    assert_reply view, %{write: true}
    render_hook(view, "predicate_error", %{})
    assert_reply view, %{allowed: false}
  end

  test "GET then ordinary live/1 works with the unmodified bridged response", %{conn: conn} do
    response = get(conn, "/")
    assert response.status == 200
    {:ok, view, _html} = live(response)
    render_hook(view, "snapshot", %{})
    assert_reply view, %{login: "alice@example.test", capabilities: @caps, read: true}
  end

  test "recycled conn uses new headers, not poisoned cookie/page/params/stale assigns", %{
    conn: conn
  } do
    response = get(conn, "/")

    next_conn =
      response
      |> tailscale_conn("bob@example.test", %{})
      |> put_connect_params(%{"current_user" => "params-admin"})

    {:ok, view, html} = live(next_conn, "/other")
    assert html =~ "bob@example.test"
    refute html =~ "alice@example.test"
    render_hook(view, "snapshot", %{})
    assert_reply view, %{login: "bob@example.test", capabilities: %{}, read: false}
    render_hook(view, "write", %{})
    assert_reply view, %{write: false}
  end

  test "new TCP-shaped test conns and invalid initial assertions still fail", %{conn: conn} do
    assert get(build_conn(), "/").status == 403

    for bad <- [
          Plug.Conn.delete_req_header(conn, "tailscale-user-login"),
          Plug.Conn.put_req_header(conn, "tailscale-app-capabilities", "bad")
        ] do
      assert get(bad, "/").status == 401
    end
  end

  test "connected mount independently rejects invalid peer or headers after valid HTTP render", %{
    conn: conn
  } do
    response = get(conn, "/")

    for changed <- [
          Plug.Test.put_peer_data(response, %{address: {127, 0, 0, 1}, port: 0}),
          %{response | req_headers: []},
          %{response | req_headers: [{"x-ash-tailscale-tailscale-user-login", ""}]}
        ] do
      assert {:error, {:redirect, %{to: "/failure"}}} = live(changed)
    end
  end

  test "missing endpoint integration fails even with simulated Unix and forged bridge headers",
       ctx do
    previous = Application.get_env(:ash_tailscale, UnbridgedEndpoint)

    Application.put_env(
      :ash_tailscale,
      UnbridgedEndpoint,
      Keyword.put(ctx.config, :server, false)
    )

    start_supervised!(UnbridgedEndpoint)
    on_exit(fn -> restore(UnbridgedEndpoint, previous) end)
    conn = Plug.Conn.put_req_header(ctx.conn, "x-ash-tailscale-tailscale-user-login", "admin")

    assert_raise ArgumentError, ~r/requires `use AshTailscale.LiveView.Endpoint`/, fn ->
      Phoenix.ConnTest.dispatch(conn, UnbridgedEndpoint, :get, "/")
    end
  end

  defp tailscale_conn(conn, login \\ "alice@example.test", caps \\ @caps) do
    conn
    |> Phoenix.ConnTest.ensure_recycled()
    |> Plug.Test.put_peer_data(%{address: {:local, ""}, port: 0, ssl_cert: nil})
    |> Plug.Conn.put_req_header("tailscale-user-login", login)
    |> Plug.Conn.put_req_header("tailscale-app-capabilities", Jason.encode!(caps))
  end

  defp restore(endpoint, nil), do: Application.delete_env(:ash_tailscale, endpoint)
  defp restore(endpoint, config), do: Application.put_env(:ash_tailscale, endpoint, config)
end
