defmodule AshTailscale.BrowserSocketTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true
  import Bitwise
  alias AshTailscale.Example.Endpoint

  @secret String.duplicate("test-only-secret-", 4)
  @host "app.example.test"
  @caps ~s({"example.com/cap/reports":[{"actions":["read"]},{"actions":["write"]}]})

  setup do
    dir = Path.join(System.tmp_dir!(), "ash-ts-#{System.unique_integer([:positive])}")
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    socket = Path.join(dir, "http.sock")
    previous = Application.get_env(:ash_tailscale, Endpoint)

    Application.put_env(
      :ash_tailscale,
      Endpoint,
      AshTailscale.Example.config(socket, @host, @secret)
    )

    start_supervised!(Endpoint)
    File.chmod!(socket, 0o600)

    on_exit(fn ->
      File.rm_rf!(dir)

      if previous,
        do: Application.put_env(:ash_tailscale, Endpoint, previous),
        else: Application.delete_env(:ash_tailscale, Endpoint)
    end)

    %{dir: dir, socket: socket}
  end

  test "adapter listens only on private Unix socket and restarts after stopped-service cleanup",
       ctx do
    assert {:ok, {:local, path}} = Bandit.PhoenixAdapter.server_info(Endpoint, :http)
    assert path == ctx.socket
    assert (File.stat!(ctx.dir).mode &&& 0o777) == 0o700
    assert (File.stat!(ctx.socket).mode &&& 0o777) == 0o600
    assert request(ctx.socket, "GET", "/").status == 200
    refute Endpoint.config(:https)
    assert Endpoint.config(:http)[:ip] == {:local, ctx.socket}

    stop_supervised!(Endpoint)
    # Bandit / OTP leave the socket inode. Never unlink a live listener.
    assert File.exists?(ctx.socket)
    File.rm!(ctx.socket)
    start_supervised!(Endpoint)
    File.chmod!(ctx.socket, 0o600)
    assert request(ctx.socket, "GET", "/").status == 200
  end

  test "HTML delivers CSRF token and a secure UI-only session; forms enforce CSRF", %{
    socket: socket
  } do
    {token, cookie, response} = session(socket)
    assert response.status == 200
    assert response.body =~ ~s(name="_csrf_token")

    assert header(response, "content-security-policy") ==
             "base-uri 'self'; frame-ancestors 'self';"

    assert header(response, "x-content-type-options") == "nosniff"
    assert header(response, "referrer-policy") == "strict-origin-when-cross-origin"
    assert header(response, "x-permitted-cross-domain-policies") == "none"
    set_cookie = header(response, "set-cookie")
    assert String.starts_with?(set_cookie, "__Host-tailscale_example=")
    assert set_cookie =~ "; path=/;"
    refute String.downcase(set_cookie) =~ "domain="
    assert set_cookie =~ "secure"
    assert set_cookie =~ "HttpOnly"
    assert set_cookie =~ "SameSite=Lax"
    assert Map.keys(decode_session(cookie)) == ["_csrf_token"]

    headers = [{"cookie", cookie}, {"content-type", "application/x-www-form-urlencoded"}]

    assert request(socket, "POST", "/form", [{"origin", "https://evil.invalid"} | headers]).status ==
             403

    assert request(socket, "POST", "/form", headers, "_csrf_token=invalid").status == 403
    valid = request(socket, "POST", "/form", headers, URI.encode_query(%{"_csrf_token" => token}))
    assert valid.status == 200
    assert Jason.decode!(valid.body)["login"] == "alice"
  end

  test "browser JSON uses the same CSRF pipeline before authentication and Ash policies", %{
    socket: socket
  } do
    {token, cookie, _} = session(socket)
    headers = [{"cookie", cookie}, {"content-type", "application/json"}]

    assert request(socket, "POST", "/json", [{"origin", "https://evil.invalid"} | headers], "{}").status ==
             403

    assert request(socket, "POST", "/json", [{"x-csrf-token", "invalid"} | headers], "{}").status ==
             403

    # Even invalid identity is rejected by CSRF first on an unsafe request.
    assert request(socket, "POST", "/json", [{"tailscale-user-login", ""} | headers], "{}").status ==
             403

    valid_headers = [{"x-csrf-token", token} | headers]
    assert request(socket, "POST", "/json", valid_headers, "{}").status == 200

    assert request(socket, "POST", "/json", [{"tailscale-user-login", ""} | valid_headers], "{}").status ==
             401

    assert request(
             socket,
             "POST",
             "/json",
             [{"tailscale-app-capabilities", "bad"} | valid_headers],
             "{}"
           ).status == 401

    assert request(
             socket,
             "POST",
             "/json",
             [{"tailscale-app-capabilities", "{}"} | valid_headers],
             "{}"
           ).status == 403

    # A cookie carries neither the previous login nor its capabilities.
    bob =
      request(socket, "POST", "/json", [{"tailscale-user-login", "bob"} | valid_headers], "{}")

    assert bob.status == 200
    assert Jason.decode!(bob.body)["login"] == "bob"

    assert request(socket, "GET", "/", [{"cookie", cookie}, {"tailscale-user-login", nil}]).status ==
             401

    # A CSRF token without its session is not sufficient.
    assert request(
             socket,
             "POST",
             "/json",
             [{"x-csrf-token", token}, {"content-type", "application/json"}],
             "{}"
           ).status == 403
  end

  test "accidentally merged TCP listener rejects forged assertions, even with valid CSRF", %{
    socket: socket
  } do
    {token, cookie, _} = session(socket)
    stop_supervised!(Endpoint)

    merged =
      Config.Reader.merge(
        [ash_tailscale: [{Endpoint, AshTailscale.Example.config(socket, @host, @secret)}]],
        ash_tailscale: [{Endpoint, [http: [ip: {127, 0, 0, 1}, port: 0]]}]
      )

    Application.put_env(:ash_tailscale, Endpoint, merged[:ash_tailscale][Endpoint])
    start_supervised!(Endpoint)
    assert {:ok, {{127, 0, 0, 1}, port}} = Bandit.PhoenixAdapter.server_info(Endpoint, :http)

    forged = [
      {"tailscale-user-login", "admin"},
      {"x-forwarded-for", "127.0.0.1"},
      {"forwarded", "for=unix;proto=https"}
    ]

    response = request({:tcp, port}, "GET", "/", forged)
    assert response.status == 401
    assert response.body == "Unauthorized"

    response =
      request(
        {:tcp, port},
        "POST",
        "/json",
        [
          {"cookie", cookie},
          {"x-csrf-token", token},
          {"content-type", "application/json"} | forged
        ],
        "{}"
      )

    assert response.status == 401
    assert response.body == "Unauthorized"
  end

  test "Serve-shaped null, empty and malformed entries deny writes, not authentication", %{
    socket: socket
  } do
    {token, cookie, _} = session(socket)
    headers = [{"cookie", cookie}, {"x-csrf-token", token}, {"content-type", "application/json"}]

    for caps <- [
          %{},
          %{"example.com/cap/reports" => nil},
          %{"example.com/cap/reports" => []},
          %{"example.com/cap/reports" => [nil, %{"actions" => "write"}, 1]}
        ] do
      assert request(
               socket,
               "POST",
               "/json",
               [{"tailscale-app-capabilities", Jason.encode!(caps)} | headers],
               "{}"
             ).status == 403
    end

    caps = %{"example.com/cap/reports" => [nil, %{"actions" => nil}, %{"actions" => ["write"]}]}

    assert request(
             socket,
             "POST",
             "/json",
             [{"tailscale-app-capabilities", Jason.encode!(caps)} | headers],
             "{}"
           ).status == 200
  end

  test "missing, duplicate and oversized HTTP assertions are rejected", %{socket: socket} do
    assert request(socket, "GET", "/", [{"tailscale-user-login", nil}]).status == 401

    assert request(socket, "GET", "/", [
             {"tailscale-user-login", "a"},
             {"tailscale-user-login", "b"}
           ]).status == 401

    assert request(socket, "GET", "/", [{"tailscale-user-name", String.duplicate("a", 4097)}]).status ==
             401

    assert request(socket, "GET", "/", [{"tailscale-user-name", String.duplicate("a", 67_000)}]).status ==
             431
  end

  defp session(socket) do
    response = request(socket, "GET", "/")
    [_, token] = Regex.run(~r/name="csrf-token" content="([^"]+)"/, response.body)
    cookie = response |> header("set-cookie") |> String.split(";", parts: 2) |> hd()
    {token, cookie, response}
  end

  defp decode_session(cookie) do
    Plug.Test.conn(:get, "https://#{@host}/")
    |> Plug.Conn.put_req_header("cookie", cookie)
    |> Map.put(:secret_key_base, @secret)
    |> Plug.Session.call(
      Plug.Session.init(
        store: :cookie,
        key: "__Host-tailscale_example",
        signing_salt: "csrf-ui-only",
        path: "/",
        secure: true
      )
    )
    |> Plug.Conn.fetch_session()
    |> Plug.Conn.get_session()
  end

  defp header(response, key), do: response.headers |> List.keyfind(key, 0) |> elem(1)

  defp request(path, method, target, headers \\ [], body \\ "") do
    defaults = [
      {"host", @host},
      {"x-forwarded-proto", "https"},
      {"tailscale-user-login", "alice"},
      {"tailscale-app-capabilities", @caps}
    ]

    headers =
      headers ++ Enum.reject(defaults, fn {key, _} -> List.keymember?(headers, key, 0) end)

    headers = Enum.reject(headers, fn {_, value} -> is_nil(value) end)

    {address, port} =
      case path do
        {:tcp, port} -> {{127, 0, 0, 1}, port}
        path -> {{:local, String.to_charlist(path)}, 0}
      end

    {:ok, socket} = :gen_tcp.connect(address, port, [:binary, active: false], 5000)

    :ok =
      :gen_tcp.send(socket, [
        "#{method} #{target} HTTP/1.1\r\n",
        Enum.map(headers, fn {key, value} -> "#{key}: #{value}\r\n" end),
        "connection: close\r\ncontent-length: #{byte_size(body)}\r\n\r\n",
        body
      ])

    raw = receive_all(socket, [])
    :gen_tcp.close(socket)
    [head, body] = String.split(raw, "\r\n\r\n", parts: 2)
    [status | lines] = String.split(head, "\r\n")

    headers =
      Enum.map(lines, fn line ->
        [key, value] = String.split(line, ":", parts: 2)
        {String.downcase(key), String.trim(value)}
      end)

    %{
      status: status |> String.split(" ") |> Enum.at(1) |> String.to_integer(),
      headers: headers,
      body: body
    }
  end

  defp receive_all(socket, parts) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, data} -> receive_all(socket, [data | parts])
      {:error, :closed} -> parts |> Enum.reverse() |> IO.iodata_to_binary()
      error -> flunk("Unix socket receive failed: #{inspect(error)}")
    end
  end
end
