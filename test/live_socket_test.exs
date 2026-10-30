defmodule AshTailscale.LiveSocketTest do
  use ExUnit.Case, async: false
  alias AshTailscale.Example
  alias AshTailscale.Test.LiveEndpoint
  alias AshTailscale.Test.UnbridgedEndpoint
  alias AshTailscale.Test.WebSocketClient, as: Client

  @moduletag capture_log: true
  @host "app.example.test"
  @secret String.duplicate("live-test-secret-", 4)
  @caps %{
    "example.com/cap/reports" => [%{"actions" => ["read", "write"]}],
    "opaque" => [nil, %{"x" => false}]
  }

  setup do
    dir = Path.join(System.tmp_dir!(), "ash-live-#{System.unique_integer([:positive])}")
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    path = Path.join(dir, "live.sock")
    previous = Application.get_env(:ash_tailscale, LiveEndpoint)
    Application.put_env(:ash_tailscale, LiveEndpoint, Example.config(path, @host, @secret))
    start_supervised!({Phoenix.PubSub, name: Example.PubSub})
    start_supervised!(LiveEndpoint)

    on_exit(fn ->
      File.rm_rf!(dir)
      restore(LiveEndpoint, previous)
    end)

    %{path: path, dir: dir}
  end

  test "real Unix upgrade precedes ordinary plugs; GET A, handshake B, params/cookie/page identities ignored",
       ctx do
    page = page(ctx.path)
    assert page.body =~ ">alice</p>"
    assert page.cookie =~ "__Host-live_test="
    {ws, response} = upgrade(ctx.path, page, [{"tailscale-user-login", "bob"}])
    assert response.status == 101
    assert join(ws, page)["status"] == "ok"
    snapshot = event(ws, page, "snapshot")
    assert snapshot["login"] == "bob"
    assert snapshot["capabilities"] == @caps
    assert snapshot["read"] == true
    assert event(ws, page, "snapshot", 1) == snapshot
    assert event(ws, page, "write")["write"] == true
    refute event(ws, page, "predicate_error")["allowed"]
  end

  test "forged internal headers are stripped despite consumer call override; canonical values win",
       ctx do
    page = page(ctx.path)

    spoofed = [
      {"x-ash-tailscale-tailscale-user-login", "admin"},
      {"x-ash-tailscale-tailscale-app-capabilities", Jason.encode!(@caps)},
      {"x-ash-tailscale-anything", "forged"},
      {"tailscale-user-login", "bob"},
      {"tailscale-app-capabilities", "{}"}
    ]

    {ws, response} = upgrade(ctx.path, page, spoofed)
    assert response.status == 101
    assert join(ws, page)["status"] == "ok"

    assert event(ws, page, "snapshot") == %{
             "login" => "bob",
             "capabilities" => %{},
             "read" => false
           }

    assert event(ws, page, "write")["write"] == false

    # Remove canonical login, leaving ONLY the attacker-controlled prefix.
    {_, response} =
      upgrade(ctx.path, page, [
        {"tailscale-user-login", nil}
        | Enum.reject(spoofed, &(elem(&1, 0) == "tailscale-user-login"))
      ])

    assert response.status == 403
  end

  test "invalid assertions cannot be replaced by session, params, page token or reserved headers",
       ctx do
    page = page(ctx.path)

    for bad <- [
          [{"tailscale-user-login", nil}],
          [{"tailscale-user-login", ""}],
          [{"tailscale-user-login", "a"}, {"tailscale-user-login", "b"}],
          [{"tailscale-app-capabilities", "bad"}],
          [{"tailscale-app-capabilities", "{}"}, {"tailscale-app-capabilities", "{}"}],
          [{"tailscale-app-capabilities", "[]"}],
          [{"tailscale-user-login", String.duplicate("a", 1025)}],
          [{"tailscale-user-name", String.duplicate("a", 4097)}]
        ] do
      forged = [{"x-ash-tailscale-tailscale-user-login", "admin"} | bad]
      {_, response} = upgrade(ctx.path, page, forged)
      assert response.status == 403
    end
  end

  test "null consumer entries authenticate as opaque JSON but deny policy", ctx do
    page = page(ctx.path)
    caps = %{"example.com/cap/reports" => nil, "unknown" => [nil, %{"nested" => [false, 7]}]}

    {ws, %{status: 101}} =
      upgrade(ctx.path, page, [{"tailscale-app-capabilities", Jason.encode!(caps)}])

    assert join(ws, page)["status"] == "ok"
    snapshot = event(ws, page, "snapshot")
    assert snapshot["capabilities"] == caps
    refute snapshot["read"]
    assert event(ws, page, "snapshot", 1) == snapshot
    refute event(ws, page, "write")["write"]
  end

  test "actual handshake enforces origin, cookie session and CSRF; longpoll is unavailable",
       ctx do
    page = page(ctx.path)

    for {headers, token} <- [
          {[{"origin", "https://evil.invalid"}], page.csrf},
          {[{"origin", "http://#{@host}"}], page.csrf},
          {[{"origin", "https://#{@host}:444"}], page.csrf},
          {[{"cookie", nil}], page.csrf},
          {[{"cookie", "__Host-live_test=forged"}], page.csrf},
          {[], nil},
          {[], "invalid"}
        ] do
      {_, response} = upgrade(ctx.path, %{page | csrf: token}, headers)
      assert response.status == 403
    end

    assert Client.request(ctx.path, "/live/longpoll?vsn=2.0.0", headers()).status == 404
  end

  test "missing bridge fails on an actual Unix upgrade even with canonical and internal assertions",
       ctx do
    page = page(ctx.path)
    path = Path.join(ctx.dir, "unbridged.sock")
    previous = Application.get_env(:ash_tailscale, UnbridgedEndpoint)
    Application.put_env(:ash_tailscale, UnbridgedEndpoint, Example.config(path, @host, @secret))
    on_exit(fn -> restore(UnbridgedEndpoint, previous) end)
    start_supervised!(UnbridgedEndpoint)
    dead_render = Client.request(path, "/", headers())
    assert dead_render.status == 500
    assert dead_render.body == "Internal Server Error"
    assert Client.request(path, "/failure", headers()).status == 401

    assert Client.request(path, "/failure", headers([{"tailscale-user-login", nil}])).status ==
             401

    {_, response} = upgrade(path, page, [{"x-ash-tailscale-tailscale-user-login", "admin"}])
    assert response.status == 403
  end

  test "accidental TCP listener rejects valid CSRF and forged assertions/remote_ip/forwarding",
       ctx do
    page = page(ctx.path)
    stop_supervised!(LiveEndpoint)
    config = Example.config(ctx.path, @host, @secret)
    config = Keyword.update!(config, :http, &Keyword.merge(&1, ip: {127, 0, 0, 1}, port: 0))
    Application.put_env(:ash_tailscale, LiveEndpoint, config)
    start_supervised!(LiveEndpoint)
    assert {:ok, {{127, 0, 0, 1}, port}} = Bandit.PhoenixAdapter.server_info(LiveEndpoint, :http)

    {_, response} =
      upgrade({:tcp, port}, page, [
        {"x-forwarded-for", "127.0.0.1"},
        {"forwarded", "for=unix;proto=https"},
        {"x-ash-tailscale-tailscale-user-login", "admin"}
      ])

    assert response.status == 403
  end

  test "rejoin and live navigation retain permissions; only a new actual WebSocket refreshes",
       ctx do
    page = page(ctx.path)
    {ws, %{status: 101}} = upgrade(ctx.path, page)
    assert join(ws, page)["status"] == "ok"
    assert event(ws, page, "snapshot")["read"]
    assert event(ws, page, "write")["write"]

    # A subsequent HTTP assertion has different grants. It cannot mutate an open transport.
    revoked =
      page(ctx.path, [{"tailscale-user-login", "bob"}, {"tailscale-app-capabilities", "{}"}])

    assert revoked.body =~ ">bob</p>"
    leave(ws, page)
    assert join(ws, page, "2")["status"] == "ok"
    assert event(ws, page, "snapshot", nil, "2")["login"] == "alice"
    assert event(ws, page, "write", nil, "2")["write"]

    leave(ws, page, "2")
    assert join(ws, page, "3", %{"redirect" => "https://#{@host}/other"})["status"] == "ok"
    assert event(ws, page, "snapshot", 1, "3")["capabilities"] == @caps

    :gen_tcp.close(ws)

    {fresh, %{status: 101}} =
      upgrade(ctx.path, page, [
        {"tailscale-user-login", "bob"},
        {"tailscale-app-capabilities", "{}"}
      ])

    assert join(fresh, page)["status"] == "ok"

    assert event(fresh, page, "snapshot") == %{
             "login" => "bob",
             "capabilities" => %{},
             "read" => false
           }

    refute event(fresh, page, "write")["write"]
  end

  test "actual mounted identity is escaped and forged page token is rejected", ctx do
    login = "<img src=x onerror=alert(1)>"
    page = page(ctx.path, [{"tailscale-user-login", login}])
    refute page.body =~ "<img"
    assert page.body =~ "&lt;img src=x onerror=alert(1)&gt;"
    {ws, %{status: 101}} = upgrade(ctx.path, page, [{"tailscale-user-login", login}])
    joined = join(ws, page)
    assert joined["status"] == "ok"
    assert Jason.encode!(joined) =~ "&lt;img"
    assert event(ws, page, "snapshot")["login"] == login
    leave(ws, page)
    assert join(ws, %{page | session: "forged"}, "2")["status"] == "error"
  end

  defp page(path, extra \\ []) do
    response = Client.request(path, "/", headers(extra))
    assert response.status == 200
    body = response.body
    [tag] = Regex.run(~r/<div[^>]*data-phx-session="[^"]+"[^>]*>/, body)

    %{
      body: body,
      cookie: response.headers["set-cookie"] |> String.split(";", parts: 2) |> hd(),
      csrf: capture(body, ~r/name="csrf-token" content="([^"]+)"/),
      id: capture(tag, ~r/ id="([^"]+)"/),
      session: capture(tag, ~r/data-phx-session="([^"]+)"/),
      static: capture(tag, ~r/data-phx-static="([^"]*)"/)
    }
  end

  defp upgrade(path, page, extra \\ []) do
    query =
      URI.encode_query(%{
        "vsn" => "2.0.0",
        "_csrf_token" => page.csrf || "",
        "login" => "params-admin"
      })

    extra = defaults(extra, [{"cookie", page.cookie}, {"origin", "https://#{@host}"}])
    {socket, response} = Client.upgrade(path, "/live/websocket?#{query}", headers(extra))
    on_exit(fn -> :gen_tcp.close(socket) end)
    {socket, response}
  end

  defp join(ws, page, ref \\ "1", extra \\ %{}) do
    payload =
      Map.merge(
        %{
          "url" => "https://#{@host}/",
          "session" => page.session,
          "static" => page.static,
          "params" => %{
            "_mounts" => 0,
            "current_user" => "params-admin",
            "capabilities" => %{"admin" => true}
          }
        },
        extra
      )

    :ok = Client.send_message(ws, [ref, ref, "lv:" <> page.id, "phx_join", payload])
    Client.reply(ws, ref)
  end

  defp event(ws, page, event, cid \\ nil, join_ref \\ "1") do
    ref = Integer.to_string(System.unique_integer([:positive]))
    payload = %{"type" => "click", "event" => event, "value" => %{}}
    payload = if cid, do: Map.put(payload, "cid", cid), else: payload
    :ok = Client.send_message(ws, [join_ref, ref, "lv:" <> page.id, "event", payload])
    reply = Client.reply(ws, ref)
    assert reply["status"] == "ok"
    reply["response"]["diff"]["r"]
  end

  defp leave(ws, page, join_ref \\ "1") do
    ref = Integer.to_string(System.unique_integer([:positive]))
    :ok = Client.send_message(ws, [join_ref, ref, "lv:" <> page.id, "phx_leave", %{}])
    assert Client.reply(ws, ref)["status"] == "ok"
  end

  defp headers(extra \\ []) do
    extra
    |> defaults([
      {"host", @host},
      {"tailscale-user-login", "alice"},
      {"tailscale-app-capabilities", Jason.encode!(@caps)}
    ])
    |> Enum.reject(fn {_, value} -> is_nil(value) end)
  end

  defp defaults(extra, defaults),
    do: extra ++ Enum.reject(defaults, fn {key, _} -> List.keymember?(extra, key, 0) end)

  defp capture(text, pattern), do: pattern |> Regex.run(text) |> Enum.at(1)

  defp restore(endpoint, nil), do: Application.delete_env(:ash_tailscale, endpoint)
  defp restore(endpoint, value), do: Application.put_env(:ash_tailscale, endpoint, value)
end
