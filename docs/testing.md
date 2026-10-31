# Testing

Keep normal test `server: false`: the runtime guard skips only network config/TS
environment variables, not the installed bridge, socket or hooks. Real wire tests
configure Unix explicitly. For policy-only tests, pass a test actor to Ash:

```elixir
caps = %{"example.com/cap/reports" => [%{"actions" => ["read"]}]}
actor = AshTailscale.test_actor!("alice@example.test", caps)
Ash.read(MyApp.Reports.Report, actor: actor)
```

Each new/recycled test connection needs simulated Unix peer data and canonical
assertions. Recycle **before** setting them:

```elixir
# Inside your existing MyAppWeb.ConnCase test module
import Phoenix.LiveViewTest

defp tailscale_conn(conn) do
  caps = %{"example.com/cap/reports" => [%{"actions" => ["read"]}]}

  conn
  |> Phoenix.ConnTest.ensure_recycled()
  |> Plug.Test.put_peer_data(%{address: {:local, ""}, port: 0, ssl_cert: nil})
  |> Plug.Conn.put_req_header("x-forwarded-proto", "https")
  |> Plug.Conn.put_req_header("tailscale-user-login", "alice@example.test")
  |> Plug.Conn.put_req_header("tailscale-app-capabilities", Jason.encode!(caps))
end

test "connected reports", %{conn: conn} do
  {:ok, _view, _html} = conn |> tailscale_conn() |> live("/reports")

  response = conn |> tailscale_conn() |> get("/reports")
  {:ok, _view, _html} = live(response)

  {:ok, _view, _html} = response |> tailscale_conn() |> live("/reports")
end
```

`live/1` consumes the already-bridged response: do not recycle between GET and
`live/1`. Prepare again for a new request, including redirect-following requests.

These are **test-adapter simulations**. They do not exercise the custom socket's
real connect callback, transport CSRF, Serve sanitization or Unix isolation.
Do not add a production bypass; retain real wire/deployment checks.

For failures: 401 usually means invalid/missing identity; 403 can be ingress,
origin, CSRF or application policy denial—check the stage, not just the number.
The [repository examples](https://github.com/leaf-insurance/ash_tailscale/tree/main/examples)
include a test-only, disposable-data launcher; they are not production deployment.
Maintainer [validation evidence](https://github.com/leaf-insurance/ash_tailscale/blob/main/docs/validation.md)
separates wire tests from operator
browser observations and records their limits.
