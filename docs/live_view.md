# Optional LiveView integration

This integration supports **router-mounted root LiveViews over WebSockets**, behind
Tailscale Serve 1.94+ and the same private Unix socket as HTTP. LiveComponents may
receive the authenticated root actor explicitly. Nested/sticky LiveViews, longpoll,
Funnel, backend HTTP TCP listeners and session-based identity are not supported.

## Permissions last until a new WebSocket connection

The initial HTTP render uses that GET's assertion. Connected mounts use the
**WebSocket upgrade's** identity and capability snapshot, independently of the GET.
Only a **new actual WebSocket connection** gets new headers from Serve. This
updates that connection's actor; it does not revoke other open connections,
existing actor copies or already-started work.

Channel rejoin, remount after a view crash, live navigation and live patch on the
same transport do **not** refresh permissions. Reconstructing an actor at mount
is not a new assertion. Read **and write** permissions can remain stale indefinitely;
there is no TTL, revocation watcher or maximum connection age. An idle timeout is
not an authentication lifetime: heartbeats/activity can keep a connection open.

Authorize every sensitive operation with Ash, but understand that re-running the
capability predicate checks the stored handshake snapshot, not current tailnet
grants. Explicitly passed component actors, `handle_info`, `handle_async`, queued
or delayed work using that actor have the same limitation. Do not persist actors
in jobs/caches or treat them as fresh request authority. Already delivered data
cannot be revoked by disconnecting.

If that lifetime is unsuitable for a read or write, perform it through a fresh
CSRF-protected HTTP request instead. The example deliberately keeps writes on the
existing `/form` and `/json` HTTP routes. A full page reload normally creates a new
connection; merely navigating within a LiveView session does not.

## 1. Dependencies and endpoint

Add `{:phoenix_live_view, "~> 1.2.13"}` to the consumer's dependencies (normally
already present in a generated Phoenix application). LiveView is the library's
only optional dependency and supplies Phoenix/HTML transitively. HTTP-only
consumers need not install LiveView. If an application already depends on LiveView,
the declared `~> 1.2.13` constraint still applies, even if it only uses our HTTP plug.
The tested integration uses Phoenix 1.8.16 / LiveView 1.2.13; older LiveView versions
are not claimed to be compatible.

Keep the [Unix-only endpoint, session and deployment configuration](deployment.md).
Install the endpoint bridge and replace the generated `/live` socket declaration:

```elixir
defmodule MyAppWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :my_app
  use AshTailscale.LiveView.Endpoint

  @session_options [
    store: :cookie,
    key: "__Host-my_app",
    signing_salt: "csrf-ui-only",
    path: "/",
    secure: true,
    http_only: true,
    same_site: "Lax"
  ]

  socket "/live", MyAppWeb.TailscaleSocket,
    websocket: [
      connect_info: [:peer_data, :x_headers, session: @session_options],
      check_csrf: true,
      check_origin: ["https://reports.your-tailnet.ts.net"]
    ],
    longpoll: false

  # Retain your other normal endpoint plugs, then:
  plug Plug.Session, @session_options
  plug MyAppWeb.Router
end
```

Replace the origin with the **exact public HTTPS origin**, not the Unix backend
host. Do not disable origin/CSRF checks. `check_origin: :conn` is inappropriate
without additional consideration: Serve's Unix proxy rewrites backend Host to
localhost. Retain your endpoint `live_view: [signing_salt: ...]` configuration and
supervised Phoenix PubSub; these support Phoenix page integrity, not identity.

**Why an endpoint macro rather than a plug?** Phoenix dispatches socket requests
before ordinary endpoint/router plugs. The bridge wraps the documented Plug
`call/2` / `super` chain before that dispatch. Its final before-compile wrapper
also surrounds ordinary consumer `call/2` overrides. Do not override the final
wrapper or integration marker from a later before-compile callback, or route
upgrades around the endpoint.

The bridge strips **all** incoming `x-ash-tailscale-*` headers on every request,
then copies only canonical Serve assertion headers on an actual Unix connection.
Duplicates and values remain intact for strict parsing. These internal headers
are not independently trusted: the socket and mount helpers also require the
installed endpoint integration and real Unix peer metadata. A missing integration
fails closed: socket validation returns `:error`, and the standard mount hook raises
a clear `ArgumentError`. Redirecting a client cannot repair this configuration error.
The marker is a trusted-code configuration invariant, not a signature;
application code must not bypass/forge it. The bridge does not authenticate or
move HTTP authentication ahead of session/CSRF protection.

## 2. Socket and root mount

```elixir
defmodule MyAppWeb.TailscaleSocket do
  use Phoenix.LiveView.Socket

  @impl true
  def connect(_params, socket, info), do: AshTailscale.LiveView.connect(socket, info)

  @impl true
  def id(_socket), do: nil
end
```

This rejects invalid handshake assertions before upgrade. Params, cookies and
signed page tokens never supply identity or capabilities. Session validation is
still mandatory for CSRF. `id/1` deliberately does not introduce a session user ID
or a per-user logout/disconnect mechanism.

Keep the existing session/CSRF/security-header/authentication browser pipeline and
apply the required hook to every protected live session:

```elixir
# MyAppWeb.Router
import Phoenix.LiveView.Router

scope "/", MyAppWeb do
  pipe_through :tailscale # fetch_session, protect_from_forgery,
                         # put_secure_browser_headers, AshTailscale.Plug
  get "/", PageController, :home # ordinary HTTP controller failure destination

  live_session :tailscale, on_mount: [{AshTailscale.LiveView, "/"}] do
    live "/reports", ReportLive
  end
end
```

The hook replaces `current_user` on disconnected and connected root mounts; it
never falls back to existing assigns, `assign_new`, parent state or session
identity. **Run it after any other hook assigning `current_user`.** Later hooks may
read the actor, but no later identity/session loader may overwrite it, including
loaders in LiveView-module hooks or `mount/3`.

For invalid identity, its argument (`"/"` here) is an application-chosen **ordinary
protected HTTP controller route**, not another LiveView using this hook.
`AshTailscale.Plug` returns 401 if the redirected HTTP request is unauthenticated.
Do not use an unprotected view or another hooked LiveView as the failure destination;
even an ordinary HTTP redirect to that LiveView can loop. Missing integration
raises a configuration error instead of redirecting.

`AshTailscale.LiveView.assign_actor/1` is available for a consumer's own failure
handling: it returns `{:error, socket}` with `current_user` cleared even when the
bridge is missing. Do not install the root hook on nested/sticky LiveViews.

Continue passing the actor to Ash explicitly:

```elixir
Ash.read(MyApp.Reports.Report, actor: socket.assigns.current_user)
```

Use the same `AshTailscale.CapabilityCheck` and consumer MFA policies as HTTP.
Capabilities stay opaque JSON; only literal predicate `true` authorizes and
predicate errors deny. Components must receive the actor from the root explicitly
and pass it to their own Ash operations. Do not trust client event payloads or
apply `Ash.PlugHelpers` to a LiveView socket.

## 3. Browser connection and example

Retain the normal CSRF meta tag and pass its token to LiveSocket. **Remove generated
`longPollFallbackMs` and any explicit LongPoll transport configuration**; setting
only the server's `longpoll: false` is not a working fallback strategy.

```javascript
const csrfToken = document.querySelector("meta[name='csrf-token']").content
const liveSocket = new LiveSocket("/live", Socket, {params: {_csrf_token: csrfToken}})
liveSocket.connect()
```

The [repository launcher](deployment.md#repository-demo-not-production) serves
`/` as the original static HEEx/HTTP demo and `/live-demo` as the optional LiveView
demo. `examples/live_view.ex` includes the root layout, client wiring, read event
and normal HTTP write form. It uses bundled dependency JS assets only for this
small repository demo; consumers keep their usual asset build. Identity text is
escaped by HEEx; never use `raw` or trust profile URLs.

## Validation boundary

Automated tests exercise actual Bandit Unix and TCP HTTP/WebSocket dispatch,
origin/session/CSRF, canonical/internal header spoofing, duplicates and malformed
assertions, GET-to-upgrade identity changes, real reconnect versus same-transport
channel rejoin/navigation, component actors, Ash policies and HTML escaping.
The WebSocket tests use a small wire client, **not a browser or real Tailscale Serve**.
A separate fresh production consumer checks that HTTP-only compilation/runtime
works with no Phoenix/LiveView present. Maintainer evidence is in
[the repository validation record](https://github.com/leaf-insurance/ash_tailscale/blob/main/docs/validation.md).

Operators must still verify their real Serve/TLS/browser boundary and test grant
changes both before and after an actual reconnect. No host services, Tailscale
configuration or live endpoints were changed by the automated tests.
