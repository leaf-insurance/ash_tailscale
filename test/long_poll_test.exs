defmodule AshTailscale.LongPollTest do
  use ExUnit.Case, async: false
  alias AshTailscale.Example
  alias AshTailscale.Test.ForgedRemoteIPPlug
  alias AshTailscale.Test.LiveEndpoint
  alias AshTailscale.Test.UnbridgedEndpoint
  alias AshTailscale.Test.WebSocketClient, as: Client

  @moduletag capture_log: true
  @host "app.example.test"
  @secret String.duplicate("longpoll-test-secret-", 4)
  @caps %{"example.com/cap/reports" => [%{"actions" => ["read", "write"]}], "opaque" => [nil]}

  setup do
    dir = Path.join(System.tmp_dir!(), "ash-lp-#{System.unique_integer([:positive])}")
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

    %{path: path, dir: dir, page: page(path)}
  end

  test "native initial GET, empty poll, NDJSON push and replies over real Unix", ctx do
    opened = request(ctx, "GET")
    assert opened.status == 200
    assert opened.json["status"] == 410
    assert opened.json["messages"] == []
    assert is_binary(opened.json["token"])
    assert opened.headers["cache-control"] == "no-store"
    token = opened.json["token"]

    idle = request(ctx, "GET", token: token)
    assert idle.status == 200
    assert idle.json == %{"status" => 204, "token" => token, "messages" => []}
    assert idle.headers["cache-control"] == "no-store"
    assert join(ctx, token)["status"] == "ok"
    assert event(ctx, token, "snapshot")["login"] == "alice"
    assert event(ctx, token, "snapshot", cid: 1)["capabilities"] == @caps
    assert event(ctx, token, "write")["write"]
    refute event(ctx, token, "predicate_error")["allowed"]
  end

  test "new logical transport requires current identity, CSRF and session before any channel",
       ctx do
    for changes <- [
          [headers: [{"tailscale-user-login", nil}]],
          [headers: [{"tailscale-user-login", ""}]],
          [headers: [{"tailscale-user-login", "a"}, {"tailscale-user-login", "b"}]],
          [headers: [{"tailscale-app-capabilities", "bad"}]],
          [headers: [{"tailscale-app-capabilities", "[]"}]],
          [headers: [{"tailscale-app-capabilities", "{}"}, {"tailscale-app-capabilities", "{}"}]],
          [headers: [{"tailscale-user-login", String.duplicate("a", 1025)}]],
          [headers: [{"cookie", nil}]],
          [headers: [{"cookie", "__Host-live_test=forged"}]],
          [params: %{"_csrf_token" => nil}],
          [params: %{"_csrf_token" => ""}],
          [params: %{"_csrf_token" => "bad"}]
        ] do
      rejected = request(ctx, "GET", changes)
      assert rejected.status == 200
      assert rejected.json == %{"status" => 403}
    end
  end

  test "reserved header spoofing cannot authenticate or replace canonical capabilities", ctx do
    forged = [
      {"x-ash-tailscale-tailscale-user-login", "admin"},
      {"x-ash-tailscale-tailscale-app-capabilities", Jason.encode!(@caps)},
      {"tailscale-user-login", nil}
    ]

    assert request(ctx, "GET", headers: forged).json == %{"status" => 403}

    opened =
      request(ctx, "GET",
        headers: [{"tailscale-user-login", "bob"}, {"tailscale-app-capabilities", "{}"} | forged]
      )

    token = opened.json["token"]
    assert opened.json["status"] == 410
    assert join(ctx, token)["status"] == "ok"

    assert event(ctx, token, "snapshot") == %{
             "login" => "bob",
             "capabilities" => %{},
             "read" => false
           }
  end

  test "origin host, scheme and port are checked on new GET, resumed poll and push", ctx do
    token = open(ctx)
    assert join(ctx, token)["status"] == "ok"

    for origin <- ["https://evil.invalid", "http://#{@host}", "https://#{@host}:444"] do
      for {method, opts} <- [{"GET", []}, {"GET", [token: token]}, {"POST", [token: token]}] do
        rejected = request(ctx, method, Keyword.put(opts, :headers, [{"origin", origin}]))
        assert rejected.status == 200
        assert rejected.json == %{"status" => 403}
      end
    end

    options =
      request(ctx, "OPTIONS",
        headers: [{"access-control-request-headers", "x-phoenix-longpoll-token"}]
      )

    assert options.status == 200
    assert options.headers["access-control-allow-headers"] == "x-phoenix-longpoll-token"
    assert options.headers["access-control-allow-methods"] == "get, post, options"
  end

  test "GET A, longpoll handshake B: page/session/params are not identity", ctx do
    assert ctx.page.body =~ ">alice</p>"

    token =
      open(ctx, headers: [{"tailscale-user-login", "bob"}, {"tailscale-app-capabilities", "{}"}])

    assert join(ctx, token)["status"] == "ok"

    assert event(ctx, token, "snapshot") == %{
             "login" => "bob",
             "capabilities" => %{},
             "read" => false
           }
  end

  test "polls, pushes, rejoin and navigation retain A; a new logical transport uses B", ctx do
    token = open(ctx)
    assert join(ctx, token)["status"] == "ok"
    later = [headers: [{"tailscale-user-login", "bob"}, {"tailscale-app-capabilities", "{}"}]]
    assert event(ctx, token, "snapshot", later)["login"] == "alice"
    assert event(ctx, token, "write", later)["write"]
    assert leave(ctx, token, "1", later)["status"] == "ok"
    assert join(ctx, token, Keyword.put(later, :join_ref, "2"))["status"] == "ok"

    assert event(ctx, token, "snapshot", Keyword.put(later, :join_ref, "2"))["capabilities"] ==
             @caps

    assert leave(ctx, token, "2", later)["status"] == "ok"
    navigation = [join_ref: "3", redirect: "https://#{@host}/other"] ++ later
    assert join(ctx, token, navigation)["status"] == "ok"
    assert event(ctx, token, "snapshot", Keyword.put(navigation, :cid, 1))["login"] == "alice"

    fresh = open(ctx, later)
    refute fresh == token
    assert join(ctx, fresh, later)["status"] == "ok"

    assert event(ctx, fresh, "snapshot", later) == %{
             "login" => "bob",
             "capabilities" => %{},
             "read" => false
           }

    refute event(ctx, fresh, "write", later)["write"]
  end

  test "ended logical server cannot be restored by its token; reconnect authenticates B", ctx do
    token = open(ctx)
    assert join(ctx, token)["status"] == "ok"
    stop_supervised!(LiveEndpoint)
    # Normal endpoint shutdown drains its transports. Remove only the stopped test listener.
    File.rm!(ctx.path)
    start_supervised!(LiveEndpoint)
    later = [headers: [{"tailscale-user-login", "bob"}, {"tailscale-app-capabilities", "{}"}]]
    opened = request(ctx, "GET", Keyword.put(later, :token, token))
    assert opened.json["status"] == 410
    fresh = opened.json["token"]
    refute fresh == token
    assert join(ctx, fresh, later)["status"] == "ok"

    assert event(ctx, fresh, "snapshot", later) == %{
             "login" => "bob",
             "capabilities" => %{},
             "read" => false
           }
  end

  test "native bearer token resumes without new session/CSRF/identity validation", ctx do
    token = open(ctx)
    assert join(ctx, token)["status"] == "ok"

    changed = [
      headers: [
        {"cookie", nil},
        {"tailscale-user-login", nil},
        {"tailscale-app-capabilities", "bad"},
        {"x-ash-tailscale-tailscale-user-login", "injected"}
      ],
      params: %{"_csrf_token" => "bad", "current_user" => "params-admin"}
    ]

    snapshot = event(ctx, token, "snapshot", changed)
    assert snapshot == %{"login" => "alice", "capabilities" => @caps, "read" => true}
    assert event(ctx, token, "write", changed)["write"]

    # The current JS client uses the query token; the server also accepts a header.
    assert event(ctx, token, "snapshot", Keyword.put(changed, :query_token, true)) == snapshot
    # Header takes precedence over a conflicting query value.
    assert event(ctx, token, "snapshot", params: %{"token" => "forged"}) == snapshot

    assert request(ctx, "POST", token: token <> "tampered").json == %{"status" => 410}
    assert request(ctx, "POST").json == %{"status" => 410}

    assert request(ctx, "GET", Keyword.put(changed, :token, token <> "tampered")).json == %{
             "status" => 403
           }

    assert request(ctx, "GET", Keyword.put(changed, :token, Jason.encode!(%{"login" => "admin"}))).json ==
             %{
               "status" => 403
             }
  end

  test "invalid and foreign tokens on GET create fresh transports only with fresh authentication",
       ctx do
    original = open(ctx)
    assert join(ctx, original)["status"] == "ok"
    foreign_ctx = start_example(ctx, String.duplicate("foreign-secret-", 5))
    foreign = open(foreign_ctx)
    later = [headers: [{"tailscale-user-login", "bob"}, {"tailscale-app-capabilities", "{}"}]]

    for unusable <- [original <> "tampered", foreign] do
      # Even a conflicting valid query token does not override the header token.
      options = Keyword.merge(later, token: unusable, params: %{"token" => original})
      fresh = open(ctx, options)
      refute fresh in [original, foreign]
      assert join(ctx, fresh)["status"] == "ok"

      assert event(ctx, fresh, "snapshot") == %{
               "login" => "bob",
               "capabilities" => %{},
               "read" => false
             }

      for missing <- ["cookie", "tailscale-user-login"] do
        rejected = request(ctx, "GET", Keyword.put(options, :headers, [{missing, nil}]))
        assert rejected.status == 200
        assert rejected.json == %{"status" => 403}
      end
    end

    # A replacement transport did not revoke or modify the original server.
    assert event(ctx, original, "snapshot")["login"] == "alice"
  end

  test "real TCP rejects new connects AND Unix-issued token poll/push before dispatch", ctx do
    token = open(ctx)
    assert join(ctx, token)["status"] == "ok"
    address = tcp_listener(LiveEndpoint)

    forged = [
      {"x-forwarded-for", "127.0.0.1"},
      {"forwarded", "for=unix;proto=https"},
      {"x-ash-tailscale-tailscale-user-login", "admin"}
    ]

    attack = [address: address, headers: forged]

    for method <- ["GET", "POST", "OPTIONS"],
        mode <- [[], [token: token], [token: token, query_token: true]] do
      rejected = request(ctx, method, attack ++ mode)
      assert rejected.status == 403
      assert rejected.body == "Forbidden"
    end

    message = [
      "1",
      "tcp-attack",
      "lv:" <> ctx.page.id,
      "event",
      %{"type" => "click", "event" => "write", "value" => %{}}
    ]

    rejected = request(ctx, "POST", attack ++ [token: token, body: Jason.encode!(message)])
    assert rejected.status == 403
    # Nothing was dispatched/buffered by the rejected token-bearing POST.
    assert request(ctx, "GET", token: token).json["status"] == 204
    assert event(ctx, token, "snapshot")["login"] == "alice"
  end

  test "UNSAFE shared-context unbridged endpoint resumes tokens: unsupported configuration",
       ctx do
    token = open(ctx)
    assert join(ctx, token)["status"] == "ok"
    unbridged = start_unbridged(ctx, @secret)

    forged = [
      {"x-ash-tailscale-tailscale-user-login", "alice"},
      {"x-ash-tailscale-tailscale-app-capabilities", Jason.encode!(@caps)}
    ]

    rejected = request(ctx, "GET", address: unbridged, headers: forged)
    assert rejected.status == 200
    assert rejected.json == %{"status" => 403}
    # The missing marker rejects NEW transports but is not a per-request resume hook.
    # Same key + PubSub salt reaches the existing server and its ORIGINAL connect_info.
    unbridged_tcp = tcp_listener(UnbridgedEndpoint)

    snapshot =
      event(ctx, token, "snapshot",
        address: unbridged_tcp,
        headers: [{"cookie", nil}, {"tailscale-user-login", "mallory"}]
      )

    assert snapshot["login"] == "alice"
    assert snapshot["capabilities"] == @caps
    # A new channel mount still checks the ORIGINAL endpoint/connect_info, not this entrypoint.
    assert leave(ctx, token, "1", address: unbridged_tcp)["status"] == "ok"
    assert join(ctx, token, address: unbridged_tcp, join_ref: "2")["status"] == "ok"

    assert event(ctx, token, "snapshot", address: unbridged_tcp, join_ref: "2")["login"] ==
             "alice"
  end

  test "different signing credentials do not resume another endpoint's token", ctx do
    token = open(ctx)
    unbridged = start_unbridged(ctx, String.duplicate("separate-secret-", 4))
    assert request(ctx, "POST", address: unbridged, token: token).json == %{"status" => 410}
    assert request(ctx, "GET", address: unbridged, token: token).json == %{"status" => 403}
  end

  test "example config enables normal fallback with identical transport connect_info", ctx do
    example = start_example(ctx, @secret)
    assert example.page.body =~ "longPollFallbackMs: 2500"
    token = open(example)
    joined = join(example, token, url: "https://#{@host}/live-demo")
    assert joined["status"] == "ok"
    assert Jason.encode!(joined) =~ "Read allowed"
  end

  defp open(ctx, opts \\ []) do
    response = request(ctx, "GET", opts)
    assert response.status == 200
    assert response.json["status"] == 410
    response.json["token"]
  end

  defp page(path, target \\ "/") do
    response = Client.request(path, target, base_headers())
    assert response.status == 200
    [tag] = Regex.run(~r/<div[^>]*data-phx-session="[^"]+"[^>]*>/, response.body)

    %{
      body: response.body,
      cookie: response.headers["set-cookie"] |> String.split(";", parts: 2) |> hd(),
      csrf: capture(response.body, ~r/name="csrf-token" content="([^"]+)"/),
      id: capture(tag, ~r/ id="([^"]+)"/),
      session: capture(tag, ~r/data-phx-session="([^"]+)"/),
      static: capture(tag, ~r/data-phx-static="([^"]*)"/)
    }
  end

  defp request(ctx, method, opts \\ []) do
    params =
      Map.merge(
        %{"vsn" => "2.0.0", "_csrf_token" => ctx.page.csrf, "login" => "params-admin"},
        Keyword.get(opts, :params, %{})
      )

    token = opts[:token]
    params = if token && opts[:query_token], do: Map.put(params, "token", token), else: params
    params = Map.reject(params, fn {_, value} -> is_nil(value) end)
    extra = Keyword.get(opts, :headers, [])

    extra =
      if token && !opts[:query_token],
        do: [{"x-phoenix-longpoll-token", token} | extra],
        else: extra

    defaults = [
      {"cookie", ctx.page.cookie},
      {"origin", "https://#{@host}"},
      {"content-type", "application/x-ndjson"} | base_headers()
    ]

    headers = extra ++ Enum.reject(defaults, fn {key, _} -> List.keymember?(extra, key, 0) end)
    headers = Enum.reject(headers, fn {_, value} -> is_nil(value) end)

    response =
      Client.request(
        Keyword.get(opts, :address, ctx.path),
        method,
        "/live/longpoll?#{URI.encode_query(params)}",
        headers,
        Keyword.get(opts, :body, "")
      )

    json =
      case Jason.decode(response.body) do
        {:ok, json} -> json
        {:error, _} -> nil
      end

    Map.put(response, :json, json)
  end

  defp join(ctx, token, opts \\ []) do
    ref = Keyword.get(opts, :join_ref, "1")

    payload = %{
      "url" => Keyword.get(opts, :url, "https://#{@host}/"),
      "session" => ctx.page.session,
      "static" => ctx.page.static,
      "params" => %{
        "_mounts" => 0,
        "current_user" => "params-admin",
        "capabilities" => %{"admin" => true}
      }
    }

    payload = if opts[:redirect], do: Map.put(payload, "redirect", opts[:redirect]), else: payload
    exchange(ctx, token, [ref, ref, "lv:" <> ctx.page.id, "phx_join", payload], opts)
  end

  defp event(ctx, token, event, opts \\ []) do
    ref = Integer.to_string(System.unique_integer([:positive]))
    payload = %{"type" => "click", "event" => event, "value" => %{}}
    payload = if opts[:cid], do: Map.put(payload, "cid", opts[:cid]), else: payload

    reply =
      exchange(
        ctx,
        token,
        [Keyword.get(opts, :join_ref, "1"), ref, "lv:" <> ctx.page.id, "event", payload],
        opts
      )

    assert reply["status"] == "ok"
    reply["response"]["diff"]["r"]
  end

  defp leave(ctx, token, join_ref, opts) do
    ref = Integer.to_string(System.unique_integer([:positive]))
    exchange(ctx, token, [join_ref, ref, "lv:" <> ctx.page.id, "phx_leave", %{}], opts)
  end

  defp exchange(ctx, token, [_, ref, _, _, _] = message, opts) do
    push = request(ctx, "POST", Keyword.merge(opts, token: token, body: Jason.encode!(message)))
    assert push.status == 200
    assert push.json == %{"status" => 200}
    poll = request(ctx, "GET", Keyword.put(opts, :token, token))
    assert poll.status == 200
    assert poll.json["status"] == 200
    assert poll.json["token"] == token
    messages = Enum.map(poll.json["messages"], &Jason.decode!/1)

    [_, ^ref, _, "phx_reply", reply] =
      Enum.find(messages, fn [_, msg_ref, _, event, _] ->
        msg_ref == ref && event == "phx_reply"
      end)

    reply
  end

  defp start_example(ctx, secret) do
    previous = Application.get_env(:ash_tailscale, Example.Endpoint)
    path = Path.join(ctx.dir, "example.sock")
    Application.put_env(:ash_tailscale, Example.Endpoint, Example.config(path, @host, secret))
    on_exit(fn -> restore(Example.Endpoint, previous) end)
    start_supervised!(Example.Endpoint)
    %{ctx | path: path, page: page(path, "/live-demo")}
  end

  defp start_unbridged(ctx, secret) do
    path = Path.join(ctx.dir, "unbridged.sock")
    previous = Application.get_env(:ash_tailscale, UnbridgedEndpoint)
    Application.put_env(:ash_tailscale, UnbridgedEndpoint, Example.config(path, @host, secret))
    on_exit(fn -> restore(UnbridgedEndpoint, previous) end)
    start_supervised!(UnbridgedEndpoint)
    path
  end

  defp tcp_listener(endpoint) do
    pid =
      start_supervised!(
        {Bandit, plug: {ForgedRemoteIPPlug, endpoint}, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(pid)
    {:tcp, port}
  end

  defp base_headers do
    [
      {"host", @host},
      {"x-forwarded-proto", "https"},
      {"tailscale-user-login", "alice"},
      {"tailscale-app-capabilities", Jason.encode!(@caps)}
    ]
  end

  defp capture(text, pattern), do: pattern |> Regex.run(text) |> Enum.at(1)
  defp restore(endpoint, nil), do: Application.delete_env(:ash_tailscale, endpoint)
  defp restore(endpoint, value), do: Application.put_env(:ash_tailscale, endpoint, value)
end
