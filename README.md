# AshTailscale

Transient [Ash Authentication](https://hexdocs.pm/ash_authentication/) actors for
Phoenix browser applications behind **Tailscale Serve 1.94+**.

**Working v0.1 slice, not published or release-tagged:** agents ran 34 automated
tests plus local socket checks. The user subsequently reported passing the agreed
manual live Serve/tailnet smoke checklist on their own setup; agents did not
directly observe that deployment. This is not a broader production-readiness or
platform guarantee. See [validation results and limits](docs/deployment.md#user-reported-manual-live-smoke-checks).

```text
Tailnet browser → Serve HTTPS / HTTP proxy → private Unix socket
    → Phoenix session + CSRF → fresh Ash actor → consumer Ash policies
```

No user database, provisioning, lookup, account mapping, authentication tokens,
or session identity. The library owns `AshTailscale.User` and its domain; login
is the primary key. Capabilities remain opaque JSON, including nested nulls.

## Integration

Use a local path dependency until a package is published:

```elixir
{:ash_tailscale, path: "../ash-tailscale"}
```

The tested consumer uses Phoenix 1.8.16, Phoenix HTML 4.3.0, Bandit 1.14.1 and
SimpleSat 0.1.4 (a consumer's Ash SAT solver). These are test-only dependencies
here; add them to your application as appropriate. Ash 3.37 requires an explicit
choice in your config:

```elixir
config :ash, default_string_length_count: :codepoints
```

Bind **only** to a private Unix socket, with no TCP fallback. Then, after approval
to configure Serve:

```sh
tailscale serve --bg --accept-app-caps=example.com/cap/my-app unix:/run/my-app/phoenix.sock
```

Use a capability namespace under a domain you control. Every protected browser
route, **including JSON writes**, must use:

```elixir
pipeline :tailscale_authenticated do
  plug :fetch_session
  plug :protect_from_forgery
  plug AshTailscale.Plug
end
```

The endpoint must configure `Plug.Session` with a `__Host-` prefixed cookie,
explicit `path: "/"`, `secure: true`, and **no Domain**, plus the actual Serve HTTPS
URL and trusted forwarded-scheme handling. Ordinary host-only cookies and
SameSite=Lax alone do not prevent sibling tailnet hosts from tossing a matching
domain cookie; see the [browser security explanation](docs/deployment.md#browser-protections). See the complete, tested
[endpoint/router](examples/browser.ex) and [socket recipe](docs/deployment.md).
The plug has no options. It accepts only Unix peers reported by the actual Plug
adapter; TCP/missing peer metadata and invalid assertions halt with generic HTTP
401 and clear stale actors. Forwarded headers and `remote_ip` cannot satisfy this
transport check. A Unix peer is **not** proof that the caller is Serve.
Success sets `conn.assigns.current_user` and `Ash.PlugHelpers.get_actor(conn)`.
The session is only for CSRF/UI state.

### Policies

Use a compile-safe MFA; the whole decoded capability map is prepended to the
extra arguments:

```elixir
policy action_type(:read) do
  authorize_if {AshTailscale.CapabilityCheck,
                predicate: {MyApp.Capabilities, :can_read?, []}}
end

# In your consumer module (this schema is entirely yours):
def can_read?(caps) do
  case caps["example.com/cap/my-app"] do
    entries when is_list(entries) ->
      Enum.any?(entries, fn
        %{"reports" => true} -> true
        _ -> false
      end)

    _ -> false
  end
end
```

Serve forwards each capability value as an array of entries or null, for example
`{"example.com/cap/my-app":[{"reports":true}]}`. This consumer evaluates each
entry independently; it does not flatten or combine permissions across scopes.
The library parser still preserves arbitrary JSON without enforcing this schema.

Only a library-built Tailscale actor and a literal `true` authorize. Exceptions,
throws, exits, non-booleans, nil and unrelated actors fail closed. The check
does not supply row-level ownership/tenancy filtering. A sole denied simple
check returns `Ash.Error.Forbidden` in the tested Ash version; policies with
independent row-filter alternatives may instead return an empty list.

See [real read/write policies](examples/reports.ex). Its private ETS report data
is a disposable example, **not** an identity store.

### Server-side builder and tests

```elixir
{:ok, actor} = AshTailscale.from_headers(conn.req_headers)
actor.capabilities # entire JSON object, unmodified values

# Policy tests only:
actor = AshTailscale.test_actor!("alice@example.com", %{"custom" => nil})
```

The builder is pure and does **not** establish trust. Never expose it to request
parameters or use the test helper as a production bypass. The plug invokes the
route-less, token-free custom strategy using an internal server-side assertion.
Subject/session reload cannot restore authority, even with Ash authorization
disabled.

## Boundaries

- Headers and provenance metadata are **not signed credentials**. Private socket
  permissions, Serve's header sanitization, and a trusted host establish trust.
- Only Serve **HTTP proxy** to a private Unix socket is supported. No backend TCP
  listener, loopback fallback, TCP forwarding, Funnel, or alternative ingress.
- Human login is required. Tagged clients without user identity are rejected.
  Shared-device visitors can be identified; identity is not tailnet membership.
- Do not persist/cache actors or capabilities in cookies, JWTs or jobs. Login can
  change or be reassigned. Display names/profile URLs never grant permissions;
  decoding failures in these optional fields yield nil, but byte-limit violations
  still reject the request.
- No LiveView, headless API integration, optional authentication, capability
  allowlist, custom Origin/Sec-Fetch-Site checks, or observation timestamps.

## Tests and compatibility

```sh
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```

Tested with Elixir **1.18.4 / OTP 28.5.0.3** and **1.20.4 / OTP 29.1.1**.
The dependency lock uses stable Ash **3.37.2** and Ash Authentication **4.15.0**;
no Ash Authentication Phoenix integration is needed. Building the upstream
authentication dependency includes its bcrypt NIF (requires a C toolchain), but
this strategy does not use passwords or tokens.

### In-process request tests

`Phoenix.ConnTest` / `Plug.Test` requests passing through `AshTailscale.Plug`
must set Unix peer data on the **test adapter before dispatch**, as well as
supply test identity headers:

```elixir
# Test-only setup; then dispatch through your endpoint/router.
conn =
  Plug.Test.conn(:get, "/")
  |> Plug.Test.put_peer_data(%{address: {:local, ""}, port: 0})
  |> Plug.Conn.put_req_header("tailscale-user-login", "alice@example.com")
```

For Phoenix controller tests, start with `Phoenix.ConnTest.build_conn()` instead
and apply the same setup before dispatch. Unsafe methods still require the normal
session cookie and matching CSRF token (form `_csrf_token` or `x-csrf-token`);
peer data and identity headers do not replace CSRF protection.

This **simulates transport for in-process tests**. It does not exercise a real
Unix socket, validate backend isolation, or prove Serve sanitizes headers. It is
not a production bypass. Real network/deployment tests remain necessary.

The repository's network tests use temporary Unix sockets and a loopback TCP listener solely to verify
rejection of accidental TCP configuration, never tailscaled. Go-generated RFC2047
fixtures are checked in; Go is needed only to regenerate them.
See [design](docs/design.md) for the security model and
[deployment](docs/deployment.md) for byte limits, commands, and the separate
user-reported live results. Those checks include browser cookie-prefix enforcement,
not a full two-user attack simulation. No named browser/server version matrix was
supplied; the tagged client's native DNS remains unvalidated. New environments
must rerun the smoke checks.
