# Optional LiveView integration

These are the changes to an **existing generated Phoenix application** for
router-mounted root LiveViews, with standard WebSocket/longpoll fallback. Keep the
[Unix-only ingress and browser setup](deployment.md): private socket, trusted Serve,
`__Host-` cookie (Secure, HttpOnly, Path=/, no Domain), and protected browser routes.
Nested/sticky LiveViews, Funnel and backend HTTP TCP listeners remain unsupported.

## 1. Endpoint and custom socket

The optional dependency is `{:phoenix_live_view, "~> 1.2.13"}`, supplying Phoenix/HTML
transitively. HTTP-only consumers need not install it; if an app already depends on
LiveView, that constraint still applies even when only using our HTTP plug. The
tested stack is Phoenix 1.8.16 / LiveView 1.2.13, not untested older LiveView versions.

After `use Phoenix.Endpoint`, install the bridge. Replace the generated `/live`
socket declaration, keeping its existing `@session_options`:

```elixir
use AshTailscale.LiveView.Endpoint

@connect_info [:peer_data, :x_headers, session: @session_options]

socket "/live", MyAppWeb.TailscaleSocket,
  websocket: [connect_info: @connect_info],
  longpoll: [connect_info: @connect_info]
```

Longpoll must have the **same connect info** as WebSocket. Simply deleting
`longpoll: false` is insufficient: `Phoenix.Endpoint.socket/3` defaults it off.
Phoenix's generator enables it explicitly, as above. Keep the generated LiveSocket
`longPollFallbackMs: 2500` option; the repository demo uses the same value. This is
a fallback delay, not a permission lifetime.

Keep the generated session/CSRF pipeline, CSRF meta tag and client `_csrf_token`
parameter, plus the endpoint signing salt and supervised PubSub. Phoenix validates
session/CSRF when creating a **new logical transport**; do not disable its default
checks. No extra `check_csrf: true` or custom CSRF code is needed.

Configure the **exact public HTTPS origin**, retaining the setup guide's HTTPS URL:

```elixir
config :my_app, MyAppWeb.Endpoint,
  check_origin: ["https://reports.your-tailnet.ts.net"]
```

Do not use `check_origin: :conn` here: Serve's Unix proxy rewrites backend Host to
localhost. Do not disable origin checks.

Keep a custom socket so invalid assertions are rejected **before any channel**
can be opened, on WebSocket upgrade or new longpoll transport creation:

```elixir
defmodule MyAppWeb.TailscaleSocket do
  use Phoenix.LiveView.Socket

  @impl true
  def connect(_params, socket, info), do: AshTailscale.LiveView.connect(socket, info)

  @impl true
  def id(_socket), do: nil
end
```

Ordinary endpoint/router plugs run too late for socket dispatch. The bridge wraps
Plug's `call/2` / `super`, strips all incoming `x-ash-tailscale-*` headers, then
copies only canonical Serve assertions, preserving duplicates and values. It
rejects non-Unix requests with HTTP 403 **before dispatch**, including resumed
longpoll GETs/POSTs. This is transport enforcement, not a replacement identity or
CSRF system. The **whole endpoint is Unix-only**, not just `/live`: static assets,
public routes and health checks also return HTTP 403 over TCP. The standalone HTTP
plug's behavior is unchanged.

Do not override the final wrapper/marker from a later before-compile callback or
route socket traffic around it. A Unix peer does not prove the caller is Serve;
private filesystem permissions and trusted host/application code remain essential.

## 2. Required root mount hook

Keep `AshTailscale.Plug` after session/CSRF protection on the browser pipeline, and
add the hook to every protected live session:

```elixir
live_session :tailscale, on_mount: [{AshTailscale.LiveView, "/"}] do
  live "/reports", ReportLive
end
```

Here `/` must be an **ordinary protected HTTP controller route**, not another
LiveView using this hook. Invalid identity clears `current_user` and redirects
there; unauthenticated HTTP requests receive 401 from `AshTailscale.Plug`. Missing
bridge integration instead raises a clear configuration `ArgumentError`; redirecting
cannot repair it. `assign_actor/1` supports custom failure handling by returning
`{:error, socket}` with the actor cleared, including when integration is missing.

Session/CSRF is gated by the **required custom socket connect callback** at logical
transport creation, not rechecked at mount. Mounts independently validate the
marker, actual peer and assertions through documented connect-info accessors.
The mount hook is not a substitute for the socket callback.

**Run this hook after other hooks assigning `current_user`.** Later hooks may read
it, but no later identity/session loader (including module hooks or `mount/3`) may
overwrite it. No `assign_new`, session, params or page-token identity fallback is used.

Pass `actor: socket.assigns.current_user` into every Ash operation and authorize
every sensitive action. Use the same opaque capabilities and consumer MFA policies
as HTTP: only literal `true` authorizes, and predicate errors deny. LiveComponents
may receive this root actor explicitly and pass it to their own Ash operations.
Do not install the root hook on nested/sticky LiveViews.

## 3. Permissions belong to the logical transport

The disconnected render uses its GET assertion. Connected mounts use the assertion
from the **WebSocket upgrade or initial longpoll transport-creation GET**, not the
page's cookie/session/params. Only a **new logical transport** gets new authority.

Repeated longpoll HTTP polls/pushes are **not reconnects**, even if Serve sends new
identity or capabilities on each request. Channel rejoin, remount, navigation and
patch also retain the original snapshot. Reconstructing an actor is not a refresh.
Reads **and writes** can remain stale for the transport's lifetime. The library
adds no TTL/revocation framework; WebSockets can remain open indefinitely. Phoenix's
native longpoll inactivity and transport-token lifetime still apply, not an
application-level permission freshness guarantee.

Components, `handle_info`, `handle_async`, queued/delayed work and actor copies have
the same snapshot limitation. A new transport does not revoke other transports or
already-started work. Do not persist actors into jobs/caches as fresh authority.
When this lifetime is unsuitable for a read or write, use a fresh CSRF-protected
HTTP request instead. The example keeps writes on `/form` and `/json` for this reason.

### Native longpoll token and installation invariant

Phoenix returns an opaque signed **transport token**, not a library-created
identity token. It locates an existing server and its original connect info.
Treat it as a bearer secret: do not expose/log its URL or value. The installed
Phoenix client sends it in the query string; the server also accepts the
`x-phoenix-longpoll-token` header.

A valid token resumes that server **without** rerunning `connect/3`, session/CSRF
extraction or identity validation. Cookies and fresh headers are not required for
resumption; the original authority is retained. **Any holder of a valid token who
can reach the service—including another tailnet user replaying it through Serve—
can resume the original actor, regardless of the current Serve identity.** There
is no per-poll human-identity binding. This is why leaking the bearer token matters,
even when all ingress is correctly routed through Serve and the Unix socket.
Origin checks still run on every request, and the endpoint wrapper independently
enforces Unix transport before Phoenix can resume anything. Tampered/unusable tokens cannot inject identity;
creating a replacement server requires fresh authentication and normal session/CSRF.
An invalid/foreign token on GET may therefore create a new logical transport rather
than simply fail. Native JSON-versus-HTTP status details are in the validation record.

**Every HTTP entrypoint capable of resuming tokens in the same signing/PubSub
context must enforce this boundary, or use isolated signing credentials/PubSub.** A token issued
through a correctly bridged endpoint can resume through an unbridged endpoint
sharing that context. Resumption does not rerun the custom socket callback; even a
subsequent channel mount validates the **original** endpoint/connect info, not the
current HTTP entrypoint. Neither helper can detect that missing wrapper. This is an **UNSAFE,
unsupported configuration**, not a promise that missing integration fails closed on
every poll. The marker is an installation invariant, not a cryptographic per-request
attestation. Keep the custom socket: it still gates all new logical transports,
including those that can open upload channels.

## In-process request tests

Every **new or recycled** ConnTest/LiveViewTest request connection must carry a
simulated Unix peer. Apply it to the current request, not an older connection.
Phoenix 1.8.16 recycling and Plug 1.20.3 dispatch preserve existing peer data, but
fresh connections default to TCP and recycling drops canonical assertion headers
by default. Recycle **before** setting peer data and headers:

```elixir
# Inside a test module using your generated MyAppWeb.ConnCase.
defp tailscale_conn(conn) do
  conn
  |> Phoenix.ConnTest.ensure_recycled()
  |> Plug.Test.put_peer_data(%{address: {:local, ""}, port: 0, ssl_cert: nil})
  |> Plug.Conn.put_req_header("tailscale-user-login", "alice@example.test")
  |> Plug.Conn.put_req_header("tailscale-app-capabilities", "{}")
end

setup %{conn: conn}, do: {:ok, conn: tailscale_conn(conn)}

test "initial and subsequent HTTP renders", %{conn: conn} do
  response = get(conn, "/reports")
  assert response.status == 200

  next_response = response |> tailscale_conn() |> get("/reports")
  assert next_response.status == 200
end
```

Use your application's route and usual canonical test assertions; `{}` grants no
capabilities. Repeat preparation for each newly built/recycled request, including
redirect-following helpers. This is **test-adapter simulation**, not evidence of
real Unix isolation, Serve assertions or transport CSRF. Never add a production
bypass for tests; retain real wire tests for those boundaries.

For standard connected LiveViewTest, keep its normal test-only dependency
(e.g. `{:lazy_html, "~> 0.1.0", only: :test}`). With the same setup/helper above:

```elixir
import Phoenix.LiveViewTest

test "connected root LiveView", %{conn: conn} do
  {:ok, _view, _html} = live(conn, "/reports")

  response = get(conn, "/reports")
  {:ok, _view, _html} = live(response)

  {:ok, _view, _html} = response |> tailscale_conn() |> live("/reports")
end
```

`live/2` issues a GET; `live/1` uses the already-bridged HTTP response, so do **not**
recycle between that GET and `live/1`. Prepare a recycled conn only for a new
request. No private connect-info override is needed: mount uses the supported
peer/header accessors, not `get_connect_info(:session)`.

These tests cover connected actors, components and application policies, **not**
the real socket connect callback, session/CSRF handshake or Unix transport
boundary. Keep the custom socket and the real wire regressions; a passing
LiveViewTest does not prove wire security.

## Example and validation

The [repository demo](deployment.md#repository-demo-not-production) keeps `/` as
the static HEEx/HTTP page and `/live-demo` as the LiveView read UI with standard
fallback and an ordinary HTTP write form. Consumers keep their normal asset build;
`examples/live_view.ex` uses dependency JS assets only for this small demo.

Automated tests use real Bandit Unix/TCP listeners and WebSocket/longpoll wire
clients, including valid-token replay over accidental TCP, origin/session/CSRF,
spoofed assertions, shared-context hazards, reconnect/rejoin semantics, policies
and escaping. They are **not browser JS, real Serve, TLS or live grant-propagation
tests**. Those operator checks remain open. See the repository
[validation record](https://github.com/leaf-insurance/ash_tailscale/blob/main/docs/validation.md).
