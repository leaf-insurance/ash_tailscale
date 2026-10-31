# AshTailscale: internal v0.1 design reference

Maintainer reference, not the consumer onboarding guide. Start with the
[quickstart](../README.md) and [setup guide](deployment.md).

Status: implemented; the initial HTTP slice passed 34 agent-run automated tests
and local socket checks. Later tooling/LiveView milestones are recorded below.
The user subsequently reported passing the agreed manual live Serve/tailnet smoke
checklist for their own setup; agents did not directly observe that deployment.
No package publication, release tag or broader production-readiness guarantee.
Research and stable dependency compatibility checked 2026-10-29. The approved
scope now includes the optional root LiveView/fallback integration described below.
See [validation](validation.md) for agent-tested versions, byte bounds,
user-reported live results and remaining coverage limits; see [setup](deployment.md)
for the current consumer recipe.

## Goal

Authenticate Phoenix applications behind `tailscale serve` using the identity
Tailscale already provides, and authorize Ash actions using application
capabilities from tailnet grants.

**No persisted users. No provisioning, user lookup, or account mapping.**
No OAuth flow, password form, or library-issued identity token.

```text
Tailnet client
  → Tailscale Serve
  → trusted identity and capability headers
  → transient Ash actor
  → Ash policies
```

Every ordinary HTTP authentication builds a fresh actor. Headers are the source of
identity; capabilities are request permissions, not permanent roles. Optional
LiveView instead retains its initial logical-transport snapshot.

The first release supports one topology and one integration: **Serve's HTTP proxy
→ private Unix socket → Phoenix browser routes with session/CSRF protection**.
Browser-driven JSON requests use the same protection. Headless API integration
and capability-only tagged clients remain out of scope.

**Owner-approved LiveView milestone:** optional router-mounted root LiveViews use
the same ingress, with a required pre-dispatch bridge and independent socket/mount
authentication. The owner chose permissions until a new logical transport, not
expiry. Native longpoll fallback is supported; repeated polls/pushes and same-transport
rejoin/remount/navigation retain the snapshot. Read and write permissions can remain
stale indefinitely on open WebSockets; native longpoll transport lifetimes apply.
See [the integration guide](live_view.md), including shared-token-context requirements.

## What Tailscale provides

According to the official [Serve documentation][serve]:

| Header | Use |
| --- | --- |
| `Tailscale-User-Login` | Required identity for a human actor |
| `Tailscale-User-Name` | Optional display name |
| `Tailscale-User-Profile-Pic` | Optional profile-picture URL |
| `Tailscale-App-Capabilities` | JSON map of capability names to parameter arrays or null |

Serve strips incoming versions of these headers before inserting its own values.
Non-ASCII values may use RFC 2047 Q encoding; decode before use, including before
parsing capability JSON.

Important limitations:

- Tagged clients have no user identity headers, but can have capabilities.
- Funnel traffic has neither identity nor capability assertions.
- Shared-device visitors can receive identity headers; identity does not prove
  membership of the server's tailnet.
- There is no stable user ID, node ID, or tailnet ID in these headers. Preserve
  the login as supplied rather than pretending it is an immutable identifier.
- Capability forwarding requires Tailscale 1.92+ and `--accept-app-caps`, but
  **this package targets 1.94+** for HTTP proxying to Unix sockets.

## Simplest application setup

Bind Phoenix only to a Unix socket, then run:

```sh
tailscale serve --bg --accept-app-caps=example.com/cap/my-app unix:/run/my-app/phoenix.sock
```

Tailscale 1.94 supports this HTTP proxy target on Unix-like systems. [CLI source][unix]
Use an application-owned directory and socket permissions allowing only the
application and the Serve daemon's intended operating-system identity to access
it. Do not add another backend HTTP listener, port publication, TCP-mode Serve/Funnel forwarding,
or another proxy to the backend. A trusted host remains part of the boundary.

The compatibility spike tested Phoenix with Bandit over a local Unix socket,
including socket creation, private permissions, and controlled stop/cleanup/restart.
The user later reported successful live Serve/Unix-socket checks, including
isolation and restart. [Local evidence, reported live results and limitations](validation.md)
are documented separately, rather than claimed as a platform/version matrix.
New deployments must repeat the smoke checks.

Use a capability namespace under a domain you control. A sample tailnet policy
fragment, assuming the group and destination tag are defined:

```json
{
  "grants": [
    {
      "src": ["group:staff"],
      "dst": ["tag:my-app"],
      "ip": ["tcp:443"],
      "app": {
        "example.com/cap/my-app": [{"actions": ["reports:read"]}]
      }
    }
  ]
}
```

The `ip` permission allows network access; `app` supplies application permissions.
Tailscale treats capability parameters as opaque JSON. The example's `actions`
schema belongs to the application, not to Tailscale or AshTailscale. It is only
an illustration: the package must not require that field or interpret its values.
[Application capabilities][caps]

Implemented and tested Phoenix pipeline (HTML and browser JSON):

```elixir
pipeline :tailscale_authenticated do
  plug :fetch_session
  plug :protect_from_forgery
  plug :put_secure_browser_headers
  plug AshTailscale.Plug
end
```

This assumes the normal endpoint `Plug.Session` setup and Phoenix's router
helpers. All protected browser routes, including JSON endpoints, must pass through
this pipeline. Authentication is required: missing identity rejects the request.
There is no `trusted_proxy` or `capability_keys` option in the initial API; the
supported topology is fixed, and Serve selects capabilities with `--accept-app-caps`.

The plug sets `conn.assigns.current_user` and the Ash actor through
`Ash.PlugHelpers`. The application does not need to define an Accounts domain,
user table, or user-resolution action. Session state supports CSRF/UI only; it
must not restore an authenticated actor.

## Actor and strategy

Provide a small, non-persisted `AshTailscale.User` resource and a library-owned
Ash domain. Use `login` as the resource's primary key, not a generated UUID.
Its data is simply (the capability schema is illustrative only):

```elixir
%AshTailscale.User{
  login: "alice@example.com",
  name: "Alice",
  profile_pic: nil,
  capabilities: %{
    "example.com/cap/my-app" => [%{"actions" => ["reports:read"]}]
  }
}
```

Keep only authentication provenance in namespaced transient metadata. The owner
chose handshake-lifetime LiveView permissions, with no timestamps or expiry framework. Do not
infer an email attribute or fetch extra profile data. Normalize missing/empty
optional fields to nil; reject a missing or empty login. Display fields never
grant access.

Use one shared, pure actor builder for header decoding and construction, called
by the plug/strategy path after the deployment boundary has been established.
Provide a test helper instead of recommending a development header-spoofing bypass.

`AshTailscale.Strategy` uses `AshAuthentication.Strategy.Custom` and the
`AshAuthentication.Strategy` protocol. Its implemented shape is:

- One `:sign_in` operation: construct the actor from a validated assertion.
- No generated HTTP login routes or redirect phases.
- `tokens_required?: false`.
- No database access or session-based user reloading.

The built-in [API-key strategy][api-key] demonstrates a route-less, token-free
strategy, but its database lookup is **not** part of this design.

Ash Authentication 4.15 requires a domain and normally generates a primary-key-based
`get_by_subject` action. The spike verified the library-owned domain, non-persisted
`Ash.DataLayer.Simple` resource and direct strategy sign-in contract. There is no
public resource sign-in action. The library explicitly defines `get_by_subject`
with a rejecting preparation; tests prove reload fails even with `authorize?: false`.
Do not use standard subject/session loaders: a subject alone cannot reconstruct
current trusted headers. This implementation introduces no identity storage.

The login is a request identity, not an immutable ownership identifier: it can
change or be reassigned. Applications must not assume otherwise when storing
references to it.

The strategy consumes only assertions produced by the trusted server-side
adapter—not login strings from request parameters or public sign-in actions.
A struct is not cryptographic proof; trusted application code is inside the
security boundary.

## Capabilities and policies

Provide just two building blocks:

1. Access to the decoded capability JSON on the current trusted actor.
2. An Ash check that passes that data to an application-supplied predicate.

Working, compile-tested API:

```elixir
policy action_type(:read) do
  authorize_if {AshTailscale.CapabilityCheck,
                predicate: {MyApp.Capabilities, :can_read?, []}}
end
```

The check calls the consumer MFA with the entire decoded capability map prepended
to the extra argument list. Values are unmodified; the predicate decides what they
mean. Remote MFA tuples work in Ash's compiled DSL. Anonymous closures are not
supported, and there is no callback framework.

The package checks provenance and decoding, not the application's schema:

- Preserve nested objects, arrays, scalars, and null values as decoded. Do not
  require `actions`, `roles`, or any particular nested shape. A present capability
  key may hold null; its presence does not imply a list.
- Do not flatten, merge, coerce, or infer permissions from capability values.
- An absent capability header yields an empty map. Missing individual keys remain
  missing; the predicate owns their meaning and any application-level validation.
- Invoke predicates only for a current, trusted `AshTailscale.User` actor; nil or
  unrelated actors fail the check. Only an explicit `true` authorizes; errors or
  other return values must never authorize.

For the sample application's schema, its predicate could look for `"reports:read"`
in an `"actions"` list and return false when absent. That logic belongs entirely
to the consumer. Applications also own any scoped-entry combination semantics,
resource filters, and ownership/tenant restrictions. A boolean predicate over
capability JSON is not automatically a row-level authorization filter. In the
tested Ash 3.37.2, a sole denied simple check returns `Ash.Error.Forbidden`.
Consumer policies with independent row-filter alternatives can instead return an
empty list; both behaviors are covered by real Ash read tests. Do not assume every
denied read automatically becomes HTTP 403.

Do not cache actors by login or persist capability snapshots in cookies, JWTs,
or background-job arguments. The same login can have different capabilities on
different requests/devices; a captured actor is not fresh authority for a job.

For v0.1, human authentication requires a login. Parse capability headers, but
reject login-less callers on human-authenticated routes. Supporting tagged,
capability-only callers can be a separate follow-up; do not fabricate a user.

## Security essentials

1. **Isolate the backend.** Headers are unsigned; the private Unix socket and
   its access permissions establish the supported boundary, not header names,
   `X-Forwarded-For`, or an apparent loopback peer. In userspace-networking mode,
   Tailscale can forward direct tailnet TCP connections to loopback, bypassing
   Serve's header sanitization if network policy permits that backend port.
   Local TCP forwarders have the same problem. Do not support a loopback fallback
   in v0.1. The plug checks actual adapter peer metadata, accepting only
   `%{address: {:local, _}}`; neither `remote_ip` nor forwarded headers can bypass
   this fixed transport requirement. This does not prove the caller is Serve.
   Privileged local processes remain trusted. [Netstack source][netstack]
2. **Parse defensively, without a schema framework.** Decode RFC 2047, parse JSON,
   require a top-level capability map, and preserve its values. Never create atoms
   from input. Keep ordinary raw/decoded byte limits, but do not build a recursive
   duplicate-key or complexity validator. Reject login/capability parsing failures;
   optional name/profile decoding failures instead yield nil. All byte-limit
   violations remain hard failures. Document the
   chosen HTTP server's header-size limits: oversized values can be rejected
   before the plug runs, especially after Q-encoding expansion.
3. **Fail closed.** Missing/invalid identity on a protected route means no actor
   and a generic authentication failure. The predicate must explicitly authorize
   protected actions. Malformed identity/capabilities are rejected, never replaced
   with session state. There is no optional-authentication mode in the initial recipe.
4. **Keep browser protections.** Configure the real Serve HTTPS URL, trusted
   forwarded-scheme handling, and `__Host-` session cookies with Secure, explicit
   Path=/ and no Domain. Ordinary SameSite=Lax/host-only cookies do not prevent a
   sibling tailnet host from tossing a domain cookie containing an attacker's
   valid CSRF session/token, while Serve attaches the victim's ambient identity.
   See [browser setup](live_view.md#1-endpoint) and
   [the scope of reported browser checks](validation.md#user-reported-manual-live-smoke-checks).
   Require Phoenix's
   standard CSRF protection on every authenticated browser route, including JSON
   writes; a normal unprotected `:api` pipeline is not supported.
5. **Avoid accidental credentials.** No bearer tokens or login cookies that
   bypass current headers. Do not combine another session's user with Tailscale
   capabilities. Logging out of application UI state cannot log out of Tailscale.

Escape display names, treat profile URLs as display data rather than server-side
fetch targets, and avoid logging raw identity/capability headers by default.
Identity alone is not a membership policy: `actor_present()` also admits identified
external users who can access a shared device.

### Header decoding

Go's RFC 2047 Q encoder can split a value into multiple encoded words, including
mid-JSON. Recognize the complete encoded-word form and concatenate decoded words
without their separating whitespace. Do not run a permissive decoder over
arbitrary substrings of raw ASCII values. Reject malformed encoded login/capability
input and invalid/empty logins. Optional display decoding failures yield nil,
without relaxing any raw/decoded byte limits. UTF-8, underscores, and split words
are tested against fixtures produced by Go's encoder.

## Phoenix scope: browser routes and optional root LiveView

Authenticate every ordinary browser request from its current headers. Use the session/CSRF pipeline
shown above for HTML and browser-driven JSON alike. Forms use Phoenix's normal
CSRF token; browser JSON clients send it in `x-csrf-token` on unsafe requests.
The endpoint session setup, token delivery, and rejected cross-site requests must
be covered by the example and integration tests. [Plug CSRF protection][csrf]

Serve attaches identity to cross-site browser requests too. Merely naming a route
an API does not protect it. Do not introduce custom `Origin` or `Sec-Fetch-Site`
validation, a CSRF opt-out, or a headless-client bypass in v0.1. Headless API
integration is out of scope. GET/HEAD routes must not perform mutations.

LiveView's transports bypass normal endpoint/router plugs. Phoenix's standard
`connect_info: [:x_headers]` does not include `Tailscale-*`. [Socket docs][phoenix]
The required pre-dispatch `call/2` wrapper strips client-supplied bridge headers,
rejects non-Unix requests with HTTP 403 before dispatch, and copies canonical
assertions only for actual Unix peers. New socket/mount validation requires that
integration, Unix metadata and valid headers; normal session/CSRF validation runs
on new logical transports. Origin checks remain enabled on all transport requests.
No session/params/page-token identity fallback is permitted.

Longpoll's native opaque transport token resumes existing server/connect-info
state without rerunning socket connect or session/CSRF extraction. Poll/push
headers do not refresh identity or permissions. All entrypoints capable of resuming
the same signing/PubSub context must enforce the Unix boundary or be isolated;
an unbridged shared-context entrypoint is **unsafe/unsupported**, not protected by
the marker on another endpoint. These are native bearer transport tokens, not
library identity tokens or fresh Serve assertions.

The owner chose **no library assertion expiry/revalidation until a new logical
transport**. Do not claim immediate or bounded policy revocation; components and
asynchronous work using that actor have the same snapshot semantics. The example
keeps revocation-sensitive writes on fresh CSRF-protected HTTP routes.

## Implemented slice

1. **Compatibility/local topology:** non-persisted resource/domain and strategy
   work with stable Ash Authentication. Bandit/Phoenix serve HTTP over a private
   Unix socket. No fallback topology or identity storage. The subsequent
   **user-reported live smoke checklist passed for that setup**; it is distinct
   from the agents' local spike and not independently observed by agents.
2. **Headers and actor:** `AshTailscale.from_headers/1` is the shared pure builder;
   RFC 2047/JSON parsing, byte limits, a thin strategy, and required-authentication
   `AshTailscale.Plug` are implemented.
3. **Capabilities:** `actor.capabilities` and `AshTailscale.CapabilityCheck` provide
   decoded-data access and a thin consumer-MFA check, with no package allowlist or
   capability schema. `AshTailscale.test_actor!/2` supports policy tests.
4. **Phoenix example:** `examples/browser.ex`, `examples/reports.ex` and the local
   launcher `examples/serve.exs` provide one tested session/CSRF/socket recipe,
   without a user database. The optional `examples/live_view.ex` adds root LiveView
   reads using the handshake snapshot, keeping writes on the original HTTP routes.

Test malformed/Unicode/split-word headers, missing/empty login, empty optional
profile values, absent/null capabilities, arbitrary nested JSON preservation,
predicate true/false/error results, nil/unrelated actors, request isolation, and
actual Ash read/write authorization. Verify that missing/bad CSRF tokens reject
browser writes and valid form/JSON requests succeed without storing identity in
the session. GET/HEAD examples must be read-only.

The normal path must need no repository, migrations, user lookup, or token
resource. Provide a direct actor-construction helper for policy tests. Keep a
real-tailnet smoke test for socket isolation, sanitized spoofed headers through
Serve, user-owned clients, and rejection of tagged clients without human identity.

The first milestone is simply:

**trusted headers → transient actor → capability-aware Ash policies.**

## Research references and compatibility

The implemented slice uses stable Ash **3.37.2**, Ash Authentication **4.15.0**,
Phoenix **1.8.16** and Bandit **1.14.1**. Ash Authentication Phoenix is not needed.
The Elixir requirement is `~> 1.18`; tests passed on Elixir **1.18.4 / OTP 28.5.0.3**
and **1.20.4 / OTP 29.1.1**. See the lockfile and [validation notes](validation.md).
Those versions describe the initial agent-run local tests. Earlier HTTP-slice
operator reports covered identity, grants, CSRF, spoofing, tagged-client rejection,
socket isolation/restart and cookie prefixes without an exact version matrix;
see [their scope](validation.md#user-reported-manual-live-smoke-checks). Later
[Docker live validation](validation.md#real-serve-https-and-operator-browser-validation)
records verified-HTTPS wire checks and a named Firefox environment, with explicit
observation limits. Neither is a full two-user cookie attack or broad platform
matrix; current-deployment tagged-client testing was deferred. Other environments
must validate their own deployment.

- [Tailscale Serve: headers and security][serve]
- [Serve capability-forwarding example][serve-example]
- [Application capabilities][caps]
- [Serve header implementation][serve-source]
- [Tailscale 1.94 CLI: Unix socket HTTP proxy targets][unix]
- [Tailscale userspace-networking TCP forwarding][netstack]
- [Plug CSRF protection][csrf]
- [Ash Authentication: custom strategies][custom]
- [Ash Authentication: Strategy protocol][strategy]
- [Ash Authentication: API-key strategy][api-key]
- [Ash policy checks][policies]
- [Phoenix socket connection information][phoenix]

[serve]: https://tailscale.com/docs/features/tailscale-serve
[serve-example]: https://tailscale.com/docs/reference/examples/serve#forward-app-capabilities-to-a-local-service
[caps]: https://tailscale.com/docs/features/access-control/grants/grants-app-capabilities
[serve-source]: https://github.com/tailscale/tailscale/blob/main/ipn/ipnlocal/serve.go
[custom]: https://github.com/team-alembic/ash_authentication/blob/v4.15.0/documentation/topics/custom-strategy.md
[strategy]: https://github.com/team-alembic/ash_authentication/blob/v4.15.0/lib/ash_authentication/strategy.ex
[api-key]: https://github.com/team-alembic/ash_authentication/tree/v4.15.0/lib/ash_authentication/strategies/api_key
[policies]: https://hexdocs.pm/ash/policies.html
[phoenix]: https://hexdocs.pm/phoenix/Phoenix.Endpoint.html#socket/3
[unix]: https://github.com/tailscale/tailscale/blob/v1.94.0/cmd/tailscale/cli/serve_v2.go
[netstack]: https://github.com/tailscale/tailscale/blob/main/wgengine/netstack/netstack.go
[csrf]: https://hexdocs.pm/plug/Plug.CSRFProtection.html
