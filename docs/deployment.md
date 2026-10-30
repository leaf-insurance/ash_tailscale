# Setup and troubleshooting

Start with an **existing Phoenix/Ash app** and the [quickstart](../README.md).
This recipe targets Bandit 1.14.1 / Phoenix 1.8.16 on Linux with systemd and
root-owned tailscaled. Add Bandit, Phoenix HTML and an Ash SAT solver (for example
`{:simple_sat, "~> 0.1.4"}`) if absent. No user table or authentication session/token
configuration is needed. Other adapters or daemon/group/ACL arrangements need
separate review/testing.

## 1. Configure the production HTTP endpoint

**Remove generated production TCP `http:` and backend `https:` configurations**,
including later `PORT`/bind-IP overrides. Do not merge this with another listener.
Phoenix HTTP must have no alternative TCP/loopback listener, container port
publication, TCP-mode Serve or Funnel path. Systemd does not configure Phoenix.

```elixir
# config/runtime.exs — replace :my_app / MyAppWeb.Endpoint.
import Config

if config_env() == :prod do
  config :my_app, MyAppWeb.Endpoint,
    adapter: Bandit.PhoenixAdapter,
    server: true,
    secret_key_base: System.fetch_env!("SECRET_KEY_BASE"),
    url: [scheme: "https", host: System.fetch_env!("TS_HOST"), port: 443],
    https: false,
    http: [
      ip: {:local, System.fetch_env!("TS_SOCKET_PATH")},
      port: 0,
      http_1_options: [max_header_length: 66_000],
      http_2_options: [enabled: false]
    ]
end
```

Port 0 belongs to a **Unix address**, not an ephemeral TCP listener. The plug
rejects TCP/missing adapter peer data, but Unix transport does not prove Serve
identity: privileged and app-user processes remain trusted.

## 2. Endpoint, session and CSRF

Adapt existing endpoint plugs, avoiding duplicate parsers/sessions. Serve
terminates HTTPS; trust the scheme header **only with private-socket ingress**:

```elixir
plug Plug.SSL, rewrite_on: [:x_forwarded_proto]
plug Plug.Parsers, parsers: [:urlencoded, :json], pass: [], json_decoder: Jason
plug Plug.Session,
  store: :cookie,
  key: "__Host-reports_session",
  path: "/",
  signing_salt: "reports-csrf-ui",
  secure: true,
  http_only: true,
  same_site: "Lax"
plug MyAppWeb.Router
```

Do **not** add a cookie Domain. The router order is `fetch_session →
protect_from_forgery → put_secure_browser_headers → AshTailscale.Plug`, as in the
quickstart. Apply it to HTML **and browser JSON** routes. Deliver
`Plug.CSRFProtection.get_csrf_token/0` in an escaped form/meta tag; forms submit
`_csrf_token`, JSON sends `x-csrf-token` with the same session cookie. Do not install
session/subject identity loaders or exempt JSON from CSRF.

`__Host-` requires Secure, Path=/ and no Domain in supporting browsers. Tailnet
siblings can be same-site; ordinary host-only/Lax cookies alone cannot stop a
sibling tossing a parent-domain CSRF cookie while Serve supplies the victim's
identity. Keep standard CSRF and browser security headers, not custom Origin or
Sec-Fetch-Site checks.

## 3. Install and start the release (Linux/systemd)

1. **Build and install your application release**, not this library's test demo.
   Build for the target OS/architecture. Below is a first install; stop the service
   before replacing an existing release. Replace `REPLACE_WITH_RELEASE_NAME`:

   ```sh
   MIX_ENV=prod mix release
   sudo install -d -m0700 /opt/reports
   sudo cp -a _build/prod/rel/REPLACE_WITH_RELEASE_NAME/. /opt/reports/
   sudo chown -R root:root /opt/reports
   sudo chmod 0600 /opt/reports/releases/COOKIE
   sudo find /opt/reports ! -path /opt/reports/releases/COOKIE -exec chmod u=rwX,go=rX {} +
   ```

   Code is root-owned and readable/executable by the service; do not embed secrets
   in it. The release cookie file stays root-only, not world-readable.

2. **Create the protected environment once.** These commands generate a strong
   secret key base and an independent release cookie, not shared example secrets:

   ```sh
   sudo install -o root -g root -m0600 /dev/null /etc/reports.env
   sudo sh -ec '
     secret=$(openssl rand -hex 64)
     cookie=$(openssl rand -hex 32)
     printf "TS_HOST=REPLACE_WITH_SERVE_HOSTNAME\nSECRET_KEY_BASE=%s\nRELEASE_COOKIE=%s\n" "$secret" "$cookie" > /etc/reports.env
   '
   sudoedit /etc/reports.env
   ```

   Set `TS_HOST` to the actual Serve HTTPS hostname. Keep these values stable;
   do not rerun generation on restarts. PID 1 reads this root:root **0600** file
   for the service. `RELEASE_COOKIE` supplies the dynamic user with a private
   cookie without reading or writing the root-owned release cookie file.

3. **Install the [example unit](https://github.com/leaf-insurance/ash_tailscale/blob/main/examples/systemd/reports.service)**,
   replace its release binary name, then start:

   ```sh
   sudo install -m0644 deps/ash_tailscale/examples/systemd/reports.service /etc/systemd/system/reports.service
   sudoedit /etc/systemd/system/reports.service
   sudo systemctl daemon-reload
   sudo systemctl enable --now reports.service
   ```

   `DynamicUser=yes` avoids manual account creation. Systemd supplies **0700**
   `/run/reports`, umask **0077** (Linux socket **0700**), a writable working directory,
   and `RELEASE_TMP` there for release operations that need temporary files.
   The unit runs foreground `bin/RELEASE_NAME start`, never `mix run` or daemon
   mode. `RuntimeDirectoryPreserve=no` cleans up the socket after stopping,
   including failure/restart cycles; `Restart=on-failure` restarts the service.
   No stale-socket unlink hook is needed. Reserve the service identity and
   `/run/reports` **exclusively for this unit**: no second app or manual process.
   Root-owned tailscaled can traverse the private directory. Persistent app data,
   if needed, requires its own managed storage, not this disposable directory.

Check `systemctl status reports` / `journalctl -u reports`. Use
`systemctl show reports -p MainPID --value` and `sudo ss -xlpn` to verify the
running BEAM owns `/run/reports/phoenix.sock`; check modes with
`sudo stat -c '%a %n' /run/reports /run/reports/phoenix.sock`. Inspect `sudo ss -ltnp`
and effective endpoint config for unintended **Phoenix HTTP** listeners. Release
management/clustering interfaces remain the consumer's responsibility.
An isolated Debian 13/systemd 257.13 container test passed DynamicUser startup,
permissions and restart cleanup. Revalidate on your target deployment; this was
not a real Serve/TLS/browser test.

## 4. Grants and Serve

Use an **untagged, user-owned browser client** and a tagged server. Define the
group/tag ownership in your tailnet policy; use your own capability namespace:

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

Network access and app permissions are separate. The `actions` schema belongs to
this example consumer; the library keeps JSON opaque. As an authorized operator,
configure Serve 1.94+ **HTTP proxy** mode once:

```sh
sudo tailscale serve --bg --accept-app-caps=example.com/cap/reports unix:/run/reports/phoenix.sock
```

This persists separately from the application unit. Do not run Serve from an
unprivileged `ExecStartPost`; systemd neither sets grants nor configures Serve.
Test the real HTTPS URL: human identity, write grant removal/restoration in one
session, missing CSRF rejection, spoofed-header sanitization, tagged-client
rejection, cross-user socket isolation, and stopped-service restart. Check browser
cookie scope/prefix enforcement too; repeat these checks for every deployment.

## Testing and troubleshooting

- **401:** check human login, capability JSON and Unix peer. Tagged clients stay
  unauthorized even with network/capability grants.
- **403:** distinguish CSRF failure from a predicate denying an Ash action. Pass
  `actor: Ash.PlugHelpers.get_actor(conn)` on each Ash call.
- **431:** Bandit's default header bound is 10,000 bytes; this recipe uses 66,000
  for Q-encoding expansion. Raw/decoded library byte limits are login 4096/1024,
  name/profile 16384/4096 each, capabilities 65536/16384. Duplicates, invalid
  login/capabilities and oversize headers reject; bad optional display decoding
  becomes nil.
- **DNS/TLS:** fix DNS separately. `curl --resolve` can diagnose with the real
  HTTPS hostname/certificate verification; never use `-k`.

For in-process tests, supply **test-adapter** peer data before dispatch:

```elixir
conn =
  Plug.Test.conn(:get, "/")
  |> Plug.Test.put_peer_data(%{address: {:local, ""}, port: 0})
  |> Plug.Conn.put_req_header("tailscale-user-login", "alice@example.com")
```

`Phoenix.ConnTest.build_conn()` can replace the first line, but still needs the
same `put_peer_data` and header calls before dispatch. Unsafe methods also need
session/CSRF. This simulates transport, not isolation or Serve. For policy tests,
use `AshTailscale.test_actor!/2`.

### Repository demo (not production)

Examples compile only in `MIX_ENV=test`, using disposable ETS data. Static HEEx
shows the assigned identity with automatic escaping; the separate write/CSRF form
is **not a login step**. `/live-demo` adds the optional
[LiveView read UI](live_view.md); writes still use fresh CSRF-protected HTTP
requests. LiveView permissions are a handshake snapshot and can remain stale
indefinitely until a new WebSocket connection. Follow the integration guide when
adding LiveView to a consumer; the HTTP pipeline alone does not protect sockets.

```sh
umask 0077
export TS_SOCKET_PATH="$(mktemp -d)/phoenix.sock" # separate from the unit's directory
export TS_HOST=your-serve-hostname
export SECRET_KEY_BASE="$(mix phx.gen.secret)"
MIX_ENV=test mix run --no-halt examples/serve.exs
```

The launcher checks ownership/mode and the bound Unix listener, refusing an
existing socket. It does not configure grants/Serve; an operator must point Serve
at this demo's path separately. Remove its directory only after stopping it.
`mix test` runs the local suite. [Maintainer validation](https://github.com/leaf-insurance/ash_tailscale/blob/main/docs/validation.md)
records user-reported live checks and limits, including no full two-user
cookie-tossing simulation or named browser/version matrix.
