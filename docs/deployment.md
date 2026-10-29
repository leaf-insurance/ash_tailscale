# Tested socket recipe and remaining release gate

## Compatibility decisions

Stable Hex versions were checked on 2026-10-29; see `mix.lock`:

| Component | Tested version |
| --- | --- |
| Elixir / Erlang | 1.18.4 / OTP 28.5.0.3; 1.20.4 / OTP 29.1.1 |
| Ash / Ash Authentication | 3.37.2 / 4.15.0 |
| Plug / Jason | 1.20.3 / 1.4.5 |
| Phoenix / Phoenix HTML | 1.8.16 / 4.3.0 |
| Bandit / Thousand Island | 1.14.1 / 1.6.0 |
| SimpleSat (example policy solver) | 0.1.4 |

The package targets Elixir 1.18+ (<2.0); the exercised OTP versions are 28 and 29.
Bandit was selected after Hex reported CVE-2026-43966 against the current
Cowlib 2.21.0 resolved by Plug Cowboy 2.9.0. Cowboy/Cowlib are not in the final
dependency lock. Phoenix/Bandit/HTML/SimpleSat are test-only here; a consumer
adds its own web stack and Ash SAT solver.

The spike proved:
- library-owned `Ash.DataLayer.Simple` resource/domain, with login as primary key;
- custom strategy protocol `:sign_in` returning a transient actor, no routes or
  tokens, and no exposed resource sign-in action;
- explicit rejecting `:get_by_subject` preparation: a serialized subject cannot
  restore identity or capabilities, including with `authorize?: false`;
- actual Phoenix HTTP requests over a local Unix socket with Bandit, private
  directory/socket modes, and controlled stop/cleanup/restart.

## Deployment boundary

Require **Tailscale >=1.94**, Serve **HTTP proxy** mode, a trusted host, and a
private socket. There is no backend TCP listener or loopback fallback.
Socket credentials do not identify a Tailscale user: any process able to connect
can forge these headers. Root and the app's OS identity are trusted.

The authentication plug enforces Unix-only transport using
`Plug.Conn.get_peer_data/1`: only `%{address: {:local, _}}` is accepted.
TCP, missing or nonlocal peer metadata produces generic HTTP 401 and clears
stale actors before any actor is built. `remote_ip` and forwarded headers are not
used for this decision. This catches accidentally merged Phoenix runtime TCP
configuration; it does **not** authenticate the Unix caller as Serve or replace
socket permissions. A temporary loopback TCP negative test verifies rejection.

The simplest tested permissions model is an app-owned directory **0700**, socket
**0600**, with a root-owned tailscaled able to access it. Configure the service
manager to create the private directory and set **umask 0077 before starting the
BEAM**. This protects the socket from its first instant of existence; chmod
after startup is not a replacement for private directory permissions.

For a daemon running as another non-root identity, arrange a narrowly scoped
OS group/ACL and review access before deployment. That arrangement has **not**
been tested here; do not loosen access to all local users. Do not publish a
container port, add another proxy, or use TCP-mode Serve/Funnel.

### Minimal executable example

The example is compiled in `MIX_ENV=test`; it is not a generated Phoenix app.
It deliberately stores only disposable, per-process report data in private ETS.
Copy the modules and adapt application data storage in a consumer.

Create a directory as the application OS user (choose your own path) and run:

```sh
mkdir -m 700 /run/my-app
umask 0077
export TS_SOCKET_PATH=/run/my-app/phoenix.sock
export TS_HOST=my-app.your-tailnet.ts.net
# Supply a strong, stable >=64-byte secret via your normal secret manager:
export SECRET_KEY_BASE='...'
MIX_ENV=test mix run --no-halt examples/serve.exs
```

`/run` directory creation usually belongs to the service manager, not an
unprivileged interactive shell. Never use the example test secret in deployment.
The Unix-only launcher checks that the directory is not a symlink, is mode 0700,
and is owned by the effective OS identity (via `id -u`). It requires explicit
configuration and refuses an existing socket path. After startup it asserts that
the adapter's running listener is the expected Unix socket. Its tested endpoint
configuration is:

```elixir
adapter: Bandit.PhoenixAdapter,
server: true,
url: [scheme: "https", host: serve_hostname, port: 443],
http: [
  ip: {:local, socket_path},
  port: 0,
  http_1_options: [max_header_length: 66_000],
  http_2_options: [enabled: false]
]
```

`port: 0` here is required for the **Unix address**; it is not an ephemeral TCP
listener. The tests assert `Bandit.PhoenixAdapter.server_info/2` returns
`{:ok, {:local, socket_path}}`. No `:https` backend listener is configured:
Serve terminates HTTPS.

Bandit/OTP leave the socket inode after shutdown. After confirming the previous
service has fully stopped, remove the stale socket **inside the private directory**
before restarting. Do not automatically unlink a live socket. A supervised
listener restart alone cannot be assumed to handle stale files; the tested
recipe is a complete service stop, cleanup, and restart. The directory must not
be writable by untrusted users.

After explicit operator approval to change Serve/network policy:

```sh
tailscale serve --bg --accept-app-caps=example.com/cap/reports unix:/run/my-app/phoenix.sock
```

This command is documented, **not executed** by this implementation. Configure
appropriate network grants and app capabilities. Serve-shaped forwarded JSON
for the example is:

```json
{"example.com/cap/reports":[{"actions":["read"]},{"actions":["write"]}]}
```

Serve capability values are arrays or null. The example consumer uses
`Enum.any?/2` over individual map entries for its own `actions` schema, ignoring
malformed entries and denying missing/null/empty grants. It never flattens entries
or unions fields across scopes. The namespace/schema are consumer choices; the
library preserves arbitrary JSON and does not interpret them. See the grant
example in [design.md](design.md).

### Browser protections

`examples/browser.ex` uses:
1. `Plug.SSL, rewrite_on: [:x_forwarded_proto]` at the endpoint, trusting that
   header only because ingress is isolated to Serve;
2. URL-encoded/JSON parsers and a signed `__Host-tailscale_example` cookie with
   explicit `path: "/"`, `secure: true`, HttpOnly, SameSite=Lax, and **no Domain**;
3. router `fetch_session → protect_from_forgery → AshTailscale.Plug` for **both**
   forms and browser JSON.

The `__Host-` prefix is essential for this ambient-identity integration.
The Public Suffix List includes `ts.net` and `*.c.ts.net`, **not every tailnet
suffix**. Siblings such as `app.tailXXXX.ts.net` and `other.tailXXXX.ts.net`
can be same-site. A sibling can set an ordinary cookie with the app's cookie name
and `Domain=tailXXXX.ts.net`; merely making the app's own cookie host-only and
SameSite=Lax does not prevent that cookie tossing. Planting an attacker's valid
CSRF session/token is especially dangerous here because Serve independently adds
the victim's current identity and capabilities.

Supporting browsers reject a `__Host-` cookie with a Domain attribute, without
Secure, or with a path other than `/`. Keep the exact case-sensitive prefix and
these attributes. Tests assert the emitted Set-Cookie attributes and normal CSRF
behavior, **not browser enforcement**: a real-browser sibling-host cookie-tossing
smoke test is still required before release. No custom origin validator is added.

The GET page delivers a normal Phoenix/Plug CSRF token. Forms submit
`_csrf_token`; JSON clients send `x-csrf-token` with the same session cookie.
Missing/bad tokens return 403 before authentication; valid tokens do not replace
current identity headers. Missing/bad identity returns 401, and denied example
write policies return 403. GET/HEAD must remain free of application mutations.
No custom Origin or Sec-Fetch-Site handling is added. Do not put JSON routes into
an unprotected API pipeline. Session contents are tested to contain only the
CSRF token, never login, actor, or capabilities.

Escape display fields and do not fetch profile URLs server-side. Avoid logging
raw assertions. Do not install standard Ash Authentication session/subject
loaders or combine another session's user with these capabilities.

## Header parsing bounds

Limits are bytes, inclusive, per relevant header:

| Header | Raw bytes | Decoded bytes |
| --- | ---: | ---: |
| User-Login | 4,096 | 1,024 |
| User-Name | 16,384 | 4,096 |
| User-Profile-Pic | 16,384 | 4,096 |
| App-Capabilities | 65,536 | 16,384 |

Missing/empty login (including whitespace-only) is invalid. Login is preserved,
not lowercased or trimmed. Missing/empty optional profile fields become nil.
Invalid optional display encoding/UTF-8/control characters also yield nil, not
authentication failure (for example a name `=?foo` or a tab). **Raw and decoded
byte-limit violations remain hard failures on all fields**, including display
fields. Login and capabilities remain strict.
Absent capabilities become `%{}`; a present empty header, invalid JSON, or
non-object top-level JSON (including top-level null) is invalid. Nested nulls,
scalars, arrays and objects are unchanged. Jason's ordinary JSON parsing
semantics apply; there is no recursive schema/duplicate-key validator.

Headers are case-insensitive; duplicate assertion headers are rejected.
Complete UTF-8 RFC2047 Q/B words are decoded; adjacent words separated by
spaces/tabs are concatenated without that whitespace. Raw ASCII underscores
remain underscores; Q underscores mean spaces. Other charsets, malformed/trailing
mixed text on values starting with `=?`, invalid UTF-8, and disallowed controls
fail decoding: identity/capability failures reject the assertion, while optional
display failures yield nil. Encoded-looking substrings inside raw JSON or display
text remain literal data. Entire ASCII display values that look like encoded
words are inherently ambiguous; display data never grants authority. Encoded JSON
formatting whitespace is allowed by the ordinary JSON parser. The HTTP server may
itself reject malformed wire headers before this handling runs.

Bandit's default HTTP/1 header-length bound is **10,000 bytes including name and
value**. The example raises it to **66,000** to accommodate the package's raw
capability limit plus header name; larger headers receive HTTP 431 before the
plug. Q encoding can expand data substantially. The example disables backend
HTTP/2. These are bounds, not a capability schema or key allowlist.

## Validation commands

```sh
mix deps.get
mix format
mix format --check-formatted
mix compile --warnings-as-errors
MIX_ENV=test mix compile --warnings-as-errors
mix test
mix hex.audit
# Optional fixture regeneration; checked-in fixture was produced with Go 1.26.4:
go run test/fixtures/generate.go > test/fixtures/go_q.json
```

The tests exercise real Ash create/read/update/destroy authorization, a consumer
row-filter alternative returning an empty list, parser/byte-bound failures,
Go Q multiword fixtures, actor isolation, subject reload rejection, literal-true
predicate handling, and real HTTP form/JSON CSRF rejection/success on a Unix socket.
They never connect to tailscaled. **34 tests pass on both tested toolchains**;
format checks and project compilation with warnings as errors pass. `mix hex.audit`
reports no retired or security-advisory packages in the final lock. A separate
launcher smoke test ran two start/stop/cleanup cycles with umask 0077: directory
0700, socket 0600, HTTP 401 without identity and 200 with a local test assertion.
The corrective-pass rerun also verified the emitted `__Host-` cookie prefix,
Path=/, Secure and absence of Domain over HTTP; it did not exercise a browser.
This was local-only, not a Serve test. Launcher preflight tests cover owned 0700
directories, wrong modes, symlinks, and rejection based on a foreign-owned 0700
`/root` directory's metadata (read-only; the latter test skips where that fixture
is unavailable). No privileged launch, ownership changes, cross-user connection
probe or daemon permission test was performed.

Dependency compilation can emit upstream
warnings (notably optional Igniter calls in Ash and Elixir 1.20 deprecations);
project compilation is checked separately with warnings as errors.

When switching OTP versions, use a separate **absolute** `MIX_BUILD_PATH` and
clean generated rebar dependency artifacts if necessary. A first alternate
toolchain attempt with a relative build path/shared rebar cache failed compiling
yamerl; a clean absolute build succeeded.

## NOT PASSED: real-tailnet release gate

The installed Tailscale CLI reports **1.102.5**, but neither Serve configuration,
grants, tailscaled, nor any host/network service was modified. No real Serve
request was made. Local socket success is **not** proof of the complete topology.

Before release, obtain approval and test on the intended deployment:
- actual Serve HTTPS → HTTP Unix target, forwarded scheme, daemon socket access;
- unauthorized local OS identities cannot connect, and no TCP backend exists;
- caller-supplied spoofed identity/capability headers are stripped/replaced by Serve;
- a human-owned tailnet client receives the expected actor and current grants;
- a tagged/login-less client is rejected; shared-device visitor policy is explicit;
- capability changes take effect on subsequent requests, with no session fallback;
- real-browser form/JSON CSRF and `__Host-` cookie enforcement at the Serve URL,
  including attempted cookie tossing from a sibling tailnet host;
- controlled service stop/cleanup/restart with the real permissions/daemon identity.

LiveView, headless APIs, tagged capability-only principals and session
authentication are not deferred pieces of this slice: they are unsupported scope.
