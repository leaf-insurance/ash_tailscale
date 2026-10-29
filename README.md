# AshTailscale

Authenticate Phoenix browser requests with Tailscale Serve, then authorize Ash
actions using your application's capability predicates. Each request gets a fresh
`AshTailscale.User`: no user database, provisioning, lookup, tokens, or session
identity. The library supplies its own resource, domain and authentication strategy;
you do not configure an Accounts domain or add a strategy to your user resource.

**Supported:** Tailscale 1.94+ HTTP proxy → private Unix socket → Phoenix browser
HTML/JSON routes with session/CSRF protection. No backend HTTP TCP listener, Funnel,
LiveView, headless APIs, or optional authentication. Tagged clients have no human
login and are rejected. Identified shared-device visitors are not necessarily
members of your tailnet.

## 1. Install in an existing Phoenix/Ash application

The first Hex release is **pending**, not published. For now use Git and commit
your dependency lockfile:

```elixir
# mix.exs — use this now:
{:ash_tailscale, github: "leaf-insurance/ash_tailscale", branch: "main"}
# After the first Hex release, replace it with:
# {:ash_tailscale, "~> 0.1.0"}
```

Run `mix deps.get`. Target Elixir 1.18+; the tested web stack is Phoenix 1.8.16 /
Bandit 1.14.1 with Ash 3.37.2 / Ash Authentication 4.15.0. Your application needs
Bandit, Phoenix HTML for HTML rendering, and an Ash SAT solver (for example
`{:simple_sat, "~> 0.1.4"}`).

The upstream authentication dependency builds a bcrypt NIF, so a C toolchain is
needed even though this strategy does not use passwords.

## 2. Isolate the endpoint and enable Serve

Follow the **[setup guide](docs/deployment.md)** before accepting traffic: it
includes Unix-only Bandit config, a production-release systemd unit with a private
runtime directory, `__Host-` session/CSRF config, and a matching tailnet grant.

The example uses capability `example.com/cap/reports`, with entries such as
`[{"actions":["read","write"]}]`. Replace the namespace with a domain you control
consistently in grants, Serve and the predicate. After configuring the grant:

```sh
tailscale serve --bg --accept-app-caps=example.com/cap/reports unix:/run/reports/phoenix.sock
```

Headers are unsigned assertions. The plug checks the actual Unix peer, **not**
`remote_ip` or forwarded addresses, but cannot prove that the caller is Serve.
Socket permissions and a trusted host remain essential.

## 3. Authenticate every browser route

With the endpoint session configuration from the setup guide, put **all**
protected HTML and browser JSON routes through this pipeline:

```elixir
# MyAppWeb.Router
pipeline :tailscale do
  plug :fetch_session
  plug :protect_from_forgery
  plug :put_secure_browser_headers
  plug AshTailscale.Plug
end

scope "/", MyAppWeb do
  pipe_through :tailscale
  post "/reports", ReportController, :create
end
```

Success sets `conn.assigns.current_user` and `Ash.PlugHelpers.get_actor(conn)`.
Missing/invalid identity or a non-Unix peer returns 401 and clears stale actors.
Forms need the normal CSRF token; browser JSON sends `x-csrf-token` with the session
cookie. Do not move JSON writes into an unprotected API pipeline. The session holds
only CSRF/UI state. GET/HEAD must not mutate application data.

## 4. Authorize Ash actions explicitly

Serve capability values are arrays or null. This **consumer-owned** predicate
evaluates each entry independently; it does not merge permissions across scopes:

```elixir
defmodule MyApp.Capabilities do
  def allowed?(caps, action) do
    case caps["example.com/cap/reports"] do
      entries when is_list(entries) ->
        Enum.any?(entries, fn
          %{"actions" => actions} when is_list(actions) -> action in actions
          _ -> false
        end)

      _ -> false
    end
  end
end
```

Add `Ash.Policy.Authorizer` to your application's resource and use the MFA check:

```elixir
# In your report resource's policies block:
policy action_type(:read) do
  authorize_if {AshTailscale.CapabilityCheck,
                predicate: {MyApp.Capabilities, :allowed?, ["read"]}}
end

policy action_type([:create, :update, :destroy]) do
  authorize_if {AshTailscale.CapabilityCheck,
                predicate: {MyApp.Capabilities, :allowed?, ["write"]}}
end
```

**Pass the actor into each Ash call**; setting it on a connection does not
automatically authorize resource operations:

```elixir
# Inside MyAppWeb.ReportController.create/2:
actor = Ash.PlugHelpers.get_actor(conn)
case Ash.create(MyApp.Reports.Report, %{title: "Browser submission"}, actor: actor) do
  {:ok, report} -> json(conn, %{id: report.id})
  {:error, %Ash.Error.Forbidden{}} -> send_resp(conn, 403, "Forbidden")
  {:error, _error} -> send_resp(conn, 500, "Request failed")
end
```

Only a valid library actor and literal `true` authorize; predicate exceptions and
non-booleans deny. The library preserves arbitrary capability JSON, including
nested nulls, without imposing this example's schema. Add your own ownership or
tenancy policies: this boolean check is not a row-level filter. A denied simple
check alone returns an Ash forbidden error; row-filter alternatives can yield
an empty read result instead. Adapt the generic error fallback to your application.

## Testing and boundaries

Use `AshTailscale.test_actor!/2` for policy tests, and see the
[setup/testing guide](docs/deployment.md#testing-and-troubleshooting) for in-process
request setup and the executable repository demo. Its static HEEx page shows who
is signed in on the initial GET, with automatic HTML escaping; the form is a
separate write-permission/CSRF demo. This adds no LiveView authentication. The
[compiled example](https://github.com/leaf-insurance/ash_tailscale/blob/main/examples/reports.ex)
uses the same predicate/schema.

Never persist actors/capabilities in cookies, JWTs, caches or jobs. Login can
change or be reassigned. Escape display fields; do not fetch profile URLs server-side.
Optional display decoding failures become nil; byte limits still apply.

[MIT license](https://github.com/leaf-insurance/ash_tailscale/blob/main/LICENSE).
Publication/release review is pending. For maintainers, the
[validation record](https://github.com/leaf-insurance/ash_tailscale/blob/main/docs/validation.md)
separates automated tests from user-reported live checks and their limitations.
