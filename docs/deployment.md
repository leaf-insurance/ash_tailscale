# Unix socket + Tailscale Serve

Use a **tagged server and an untagged, user-owned client**. Tagged clients do not
supply human login for new authenticated requests/transports. This recipe uses
Bandit and Tailscale Serve **1.94+ HTTP proxy** mode, not TCP forwarding or Funnel.

## 1. Private endpoint

Serve assertions are **unsigned headers**. The library checks actual adapter Unix
peer metadata, not `remote_ip`; it cannot prove the caller is Serve. Trust the host
and proxy, and restrict the socket to the app and trusted tailscaled process.

Create an app-owned **0700** directory, launch with umask **0077**, and keep the
socket **0600 or 0700**. Root tailscaled can access it; other arrangements need
equivalent isolation. Do not share the app's OS identity with untrusted processes.
The [optional systemd recipe](systemd.md) manages this directory and its lifecycle.

**Replace**, rather than merge with, generated production TCP `http:`/`https:`
listeners and later PORT/bind-IP overrides. No alternative HTTP listener or
container port publication:

```elixir
# config/runtime.exs — development and production both use Unix ingress
# Keep your existing private SECRET_KEY_BASE and server-start configuration.
if config_env() != :test do
  host = System.fetch_env!("TS_HOST")

  config :my_app, MyAppWeb.Endpoint,
    adapter: Bandit.PhoenixAdapter,
    url: [scheme: "https", host: host, port: 443],
    check_origin: ["https://#{host}"],
    https: false,
    http: [
      ip: {:local, System.fetch_env!("TS_SOCKET_PATH")},
      port: 0,
      http_1_options: [max_header_length: 66_000],
      http_2_options: [enabled: false]
    ]
end
```

Set `TS_HOST` to the actual Serve HTTPS hostname and `TS_SOCKET_PATH` to the
private absolute socket path. Port 0 here belongs to a Unix address, not TCP.
Use the exact origin above, not `check_origin: :conn`: Serve rewrites backend Host.
**Remove the generated `force_ssl` block from `config/prod.exs`** and any other
localhost/loopback exclusions. Keep **one** declaration in `config/config.exs`, with no
duplicate SSL plug. Later config deep-merges can restore exclusions; Serve's
backend Host is localhost, so it must not be excluded from SSL handling:

```elixir
# config/config.exs
config :my_app, MyAppWeb.Endpoint, force_ssl: [rewrite_on: [:x_forwarded_proto], exclude: []]
```

Trust that scheme header **only through this private ingress**. Keep the
[LiveView guide's session-cookie hardening](live_view.md#1-endpoint) and normal
Phoenix CSRF protection. The 66,000-byte header bound accommodates encoded assertions;
the library still enforces its own raw/decoded limits.

## 2. Grant and Serve

Using your existing group/tag definitions, allow network access **and** application
capabilities. Use the same namespace as your predicate:

```json
{
  "grants": [{
    "src": ["group:staff"],
    "dst": ["tag:reports"],
    "ip": ["tcp:443"],
    "app": {"example.com/cap/reports": [{"actions": ["read", "write"]}]}
  }]
}
```

As the authorized operator, point Serve at that socket:

```sh
sudo tailscale serve --bg --accept-app-caps=example.com/cap/reports unix:/run/reports/phoenix.sock
```

Check the real HTTPS URL, socket ownership/modes and absence of backend HTTP TCP
listeners. Test identity, grants, CSRF and spoof rejection in your deployment;
never disable TLS verification to work around DNS/certificate failures.
Identified shared-device visitors are not necessarily members of your tailnet:
identity alone is not permission. See [testing](testing.md) for local test setup.
