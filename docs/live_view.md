# LiveView setup

For an existing Phoenix/LiveView/Ash application and its resources. Substitute your
module names and routes below. Keep your normal Phoenix session/CSRF/client setup,
including standard fallback; no account or session-identity integration is needed.
Before accepting traffic, complete the [private Unix + Serve deployment](deployment.md).

## 1. Endpoint

Keep your existing `@session_options` definition. Insert this block after it and
**after `use Phoenix.Endpoint`**, before the socket and `Plug.Session` uses.
It preserves your store/signing salt while hardening the cookie:

```elixir
use AshTailscale.LiveView.Endpoint

@session_options Keyword.merge(
                   Keyword.delete(@session_options, :domain),
                   key: "__Host-my_app_session",
                   secure: true,
                   http_only: true,
                   path: "/"
                 )

@connect_info [:peer_data, :x_headers, session: @session_options]

socket "/live", MyAppWeb.TailscaleSocket,
  websocket: [connect_info: @connect_info],
  longpoll: [connect_info: @connect_info]
```

Replace the existing `/live` declaration, don't add a second one. Both transports
need this same connect info. Keep default CSRF checks enabled; deployment sets
the exact public HTTPS origin. The bridge makes the **whole endpoint Unix-only**,
including assets, public routes and health checks. Development needs Unix too:
keeping localhost:4000 TCP instead results in HTTP 403, not a development bypass.

The custom socket is **required**, even with the mount hook:

```elixir
defmodule MyAppWeb.TailscaleSocket do
  use Phoenix.LiveView.Socket

  @impl true
  def connect(_params, socket, info), do: AshTailscale.LiveView.connect(socket, info)

  @impl true
  def id(_socket), do: nil
end
```

## 2. Protect routes

Add this to your **existing browser pipeline**, after `:fetch_session`,
`:protect_from_forgery` and `:put_secure_browser_headers`. Use that pipeline for
protected HTML and browser JSON too:

```elixir
plug AshTailscale.Plug
```

Add the hook to each protected `live_session` in your existing browser scope:

```elixir
live_session :reports, on_mount: [{AshTailscale.LiveView, "/"}] do
  live "/reports", ReportLive
end
```

Replace `"/"` with an **existing protected HTTP controller route**, not a LiveView:
invalid identity redirects there and the HTTP plug rejects it with HTTP 401.
Append this hook after all other `current_user` assigners; no later hook or
`mount/3` may overwrite the actor. Root LiveViews only; pass the root actor
explicitly to LiveComponents. Nested/sticky LiveViews are not supported.

## 3. Authorize Ash actions

Pass the actor on **every** operation; connection assigns do not do this for you:

```elixir
Ash.read(MyApp.Reports.Report, actor: socket.assigns.current_user)
Ash.create(MyApp.Reports.Report, %{title: "Draft"}, actor: socket.assigns.current_user)
```

For ordinary HTTP actions use `Ash.PlugHelpers.get_actor(conn)` instead.
In your existing resource, include `Ash.Policy.Authorizer` in `authorizers:`
and add these policies to its `policies` block:

```elixir
policy action_type(:read) do
  authorize_if {AshTailscale.CapabilityCheck,
                predicate: {MyApp.Capabilities, :allowed?, ["read"]}}
end

policy action_type([:create, :update, :destroy]) do
  authorize_if {AshTailscale.CapabilityCheck,
                predicate: {MyApp.Capabilities, :allowed?, ["write"]}}
end
```

The predicate receives the complete, opaque capability map. This minimal schema
matches the [deployment grant](deployment.md#2-grant-and-serve):

```elixir
defmodule MyApp.Capabilities do
  def allowed?(caps, action) do
    case caps["example.com/cap/reports"] do
      entries when is_list(entries) ->
        Enum.any?(entries, fn
          %{"actions" => actions} when is_list(actions) -> action in actions
          _ -> false
        end)

      _ ->
        false
    end
  end
end
```

Only literal `true` authorizes; predicate errors/non-booleans deny. Handle Ash
errors in your UI and keep your ownership/tenancy policies: this check is
action-level, not a row filter. Use a namespace you control consistently in the
predicate, grant and Serve command.

## Permission lifetime and trust

- **Transport snapshot:** polls/pushes, rejoin, remount and navigation do not refresh
  authority. Reads and writes may stay stale indefinitely; there is no bounded
  revocation guarantee. New transports do not revoke old ones or actor copies.
  For operations needing current grants, use fresh CSRF-protected HTTP requests.
- **Native longpoll tokens are bearer secrets:** any holder who can reach the
  service, including another tailnet user, can resume the original actor without
  fresh identity/session authentication. Never log their values or token-bearing
  URLs. **Every entrypoint sharing signing keys/PubSub must enforce the Unix
  boundary, or isolate those keys/PubSub.** The socket callback alone cannot guard
  resumed polls.
- Never persist actors/capabilities as later authority in sessions, caches or jobs.
  Escape display fields; do not fetch profile URLs server-side.

For in-process tests, see [testing](testing.md). API details are in
`AshTailscale.LiveView` and `AshTailscale.CapabilityCheck`.
