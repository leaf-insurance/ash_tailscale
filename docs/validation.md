# Maintainer validation record

This is maintainer evidence, not the consumer setup guide or a promise of general
production readiness. Start with [README](../README.md) and [setup](deployment.md).
The internal [design](design.md) retains research references and scope decisions.
[Maintainer commands and workflows](maintenance.md) cover local checks and release gates.
Earlier milestone limits below are historical. The latest scoped evidence is in
[real Serve HTTPS and operator browser validation](#real-serve-https-and-operator-browser-validation).

## Compatibility decisions

Stable Hex versions were checked on 2026-10-29; see `mix.lock`. This is the
**agent-tested local dependency set**, not a version matrix for the later
user-reported live deployment:

| Component | Tested version |
| --- | --- |
| Elixir / Erlang | 1.18.4 / OTP 28.5.0.3; 1.20.4 / OTP 29.1.1 |
| Ash / Ash Authentication | 3.37.2 / 4.15.0 |
| Plug / Jason | 1.20.3 / 1.4.5 |
| Phoenix / Phoenix HTML | 1.8.16 / 4.3.0 |
| Phoenix LiveView (optional root integration and HEEx tooling) | 1.2.13 |
| Bandit / Thousand Island | 1.14.1 / 1.6.0 |
| SimpleSat (example policy solver) | 0.1.4 |

The package targets Elixir 1.18+ (<2.0); the exercised OTP versions are 28 and 29.
Bandit was selected after Hex reported CVE-2026-43966 against the current
Cowlib 2.21.0 resolved by Plug Cowboy 2.9.0. Cowboy/Cowlib are not in the final
dependency lock. Phoenix LiveView is the sole **optional** dependency, providing
Phoenix/HTML transitively for root LiveView integration and repository formatting/
rendering. HTTP-only consumers need not install LiveView. When a consumer already
depends on LiveView, the declared `~> 1.2.13` constraint applies. Bandit/SimpleSat remain test-only. ExDoc is dev-only and Sourceror
dev/test-only, both runtime: false. A consumer adds its own web stack and Ash SAT
solver.

The spike proved:
- library-owned `Ash.DataLayer.Simple` resource/domain, with login as primary key;
- custom strategy protocol `:sign_in` returning a transient actor, no routes or
  tokens, and no exposed resource sign-in action;
- explicit rejecting `:get_by_subject` preparation: a serialized subject cannot
  restore identity or capabilities, including with `authorize?: false`;
- actual Phoenix HTTP requests over a local Unix socket with Bandit, private
  directory/socket modes, and controlled stop/cleanup/restart.

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

## Initial agent-run automated and local validation (34 tests)

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

The 34 agent-run automated tests exercise real Ash create/read/update/destroy
authorization, a consumer row-filter alternative returning an empty list,
parser/byte-bound failures,
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
is unavailable). Agents performed no privileged launch, ownership changes,
cross-user connection probe or daemon permission test; the later operator-reported
socket isolation checks are recorded separately below.

Dependency compilation can emit upstream
warnings (notably optional Igniter calls in Ash and Elixir 1.20 deprecations);
project compilation is checked separately with warnings as errors.

When switching OTP versions, use a separate **absolute** `MIX_BUILD_PATH` and
clean generated rebar dependency artifacts if necessary. A first alternate
toolchain attempt with a relative build path/shared rebar cache failed compiling
yamerl; a clean absolute build succeeded.

## User-reported manual live smoke checks

**Agreed manual smoke checklist: passed for the user's tested setup, as reported
by the user.** These later checks ran on the operator's own server/tailnet and were
not directly observed by the implementation or orchestration agents. No exact
browser/server version matrix was supplied for this earlier HTTP/static slice;
the later Docker/LiveView deployment is recorded separately below.

Reported results:
- **Human identity and current grants:** a browser on a user-owned client
  authenticated and an Ash create returned the expected real login. Removing
  write permission yielded 403; restoring it yielded 200 in the **same session**.
- **CSRF:** submitting without a token yielded 403/`InvalidCSRFTokenError`;
  normal form submission succeeded.
- **Header sanitization:** forging `Tailscale-User-Login` still returned the true
  login. Forging `Tailscale-App-Capabilities` while write permission was removed
  still yielded 403.
- **Tagged client:** a separate tagged client granted TCP 443 and read/write
  capabilities received 401. It had read-only `resolv.conf`/DNS health warnings;
  the test used `curl --resolve` with the server address and HTTPS hostname,
  **not `-k`**, retaining TLS certificate verification. Native DNS was neither
  fixed nor validated.
- **Socket isolation and restart:** the app OS account connected and received 401
  without identity headers; an unrelated unprivileged OS account could not
  connect. With Serve left running, the operator stopped Phoenix, removed the
  stale socket, restarted it, and successfully submitted from the real browser.
- **Browser cookie enforcement:** a sibling-host test accepted an ordinary
  parent-domain control cookie but rejected an attempted `__Host-` cookie with
  Domain. The actual application cookie was verified as Secure, HttpOnly, Path=/
  and scoped to the exact hostname. The normal form worked, and the user reported
  completing all cleanup instructions.

The reviewed public suffix list includes `ts.net` and `*.c.ts.net`, not every
tailnet suffix; same-site sibling hosts motivate the cookie-tossing defense.
The cookie check validates real-browser prefix enforcement/configuration only,
**not a complete two-user privilege-escalation attack simulation**. These earlier
reports did not supply a named browser/version matrix or validate tagged-client
native DNS. Broader server/platform coverage remains a gap. New environments must rerun the smoke checks, including their
socket/daemon permissions and browser behavior; these reports are not a general
production-readiness guarantee. No package publication or release tag is implied.

Historically, the agents' local CLI reported Tailscale **1.102.5**, but agents
made no real Serve requests and did not change tailscaled, Serve, grants or host
services. The later operator-run live checks above are separate evidence, not
retroactive claims about agent testing.

The later owner-approved root LiveView milestone is recorded below. Headless
APIs, tagged capability-only principals and session authentication remain outside
this slice.

## Documentation and packaging preparation

The owner approved MIT with copyright 2026 Philip Munksgaard; `LICENSE` and
package metadata now record that choice. Release review is still required; no
release tag or package publication has been made. ExDoc uses the existing
repository's `main` source links by default; the release workflow supplies the
actual validated tag through `ASH_TAILSCALE_SOURCE_REF`.
The unreleased Git preview uses a committed dependency lockfile; pin the release
and update source links when that real release exists, not with an invented tag.

Consumer HexDocs navigation consists of README, setup, the optional LiveView guide,
and public module docs.
This record and the internal design remain repository references, not navigation
entries. Examples/docs are included in the package; generated `doc/` output is
ignored, not shipped. The demo and test commands are for a repository checkout.

Preparation checks (never substitute `hex.publish`):
```sh
mix format
mix format --check-formatted
MIX_ENV=test mix format --check-formatted
mix compile --warnings-as-errors
MIX_ENV=test mix compile --warnings-as-errors
mix test
mix docs --warnings-as-errors
mix hex.build --output /tmp/ash_tailscale-0.1.0-docs-check.tar
```

The preparation pass added three public-API doctests and two HTTP assertions for
the approved demo change: initial GET displays the assigned actor's name/login,
automatically escaped by a static HEEx HTML module, above a separately labelled
write/CSRF form. The controller passes the CSRF token to normal view rendering;
identity stays in the existing connection assigns. No raw/HTML-safe escape bypass,
live socket, mount or LiveView session was used at that stage. That suite was
**36 tests + 3 doctests, zero failures**, on both recorded Elixir/OTP toolchains.
Authentication behavior is unchanged. The example now retains Phoenix's standard
`put_secure_browser_headers`; HTTP tests assert its CSP framing/base-URI policy,
content-type protection, referrer policy and cross-domain-policy defaults.

The initial systemd-analyze 261.3 syntax check reported the expected nonexistent
placeholder executable; a temporary copy with an existing inert executable passed.
That check alone did not test service startup.

A subsequent **agent-run isolated Docker test passed actual systemd lifecycle
checks** on Debian 13 (trixie), systemd 257.13-1~deb13u1, Elixir 1.18.4 and
OTP 28.5.0.8. It built a real production consumer release with the package as a
path dependency and copies of the static HEEx examples. The installed unit was
byte-identical except for substituting the ExecStart executable placeholder with
`/opt/reports/bin/reports`; its SHA256 was
`5cacf58cc5a4989b3d2e78ea4fd564d19d92e6dd4dfcaa9b31782b3b4da98b7a`.

Observed passes:
- Foreground release booted under DynamicUser UID 63908; runtime directory and
  Linux Unix socket were both **0700**. Environment file and release COOKIE were
  root:root **0600**; an independent active cookie came from the protected file.
- Runtime-only endpoint configuration applied from environment; RELEASE_TMP
  pointed into the private runtime directory. **No runtime `*.config` file was
  present after boot**; the recorded release marker was `RUNTIME_CONFIG=false`.
  No generated runtime-file mode or deletion behavior is claimed.
- Unix GET returned 200 with alice's identity and browser security headers;
  missing identity returned 401, and malicious display text was HTML-escaped.
- `nobody` could neither traverse/connect to the socket nor read secret files.
  Normal EPMD/distribution remained enabled, with no additional Phoenix TCP
  listener; distribution policy remains the consumer's responsibility.
- Explicit restart and SIGKILL-triggered automatic restart replaced the PID,
  removed runtime markers/old socket and served through a fresh listener.
  Intentional stop removed the whole runtime directory and stayed inactive;
  subsequent start worked with the same environment. Final stop cleaned up again.

The containers used no network, published ports or host bind mounts, with a
private cgroup namespace. They were **not privileged**, but nested systemd
required CAP_SYS_ADMIN and seccomp=unconfined. Only image building fetched
dependencies. No host units/services or Tailscale configuration were changed.
Both containers were stopped/removed; images and temporary evidence were retained.

Evidence is under `/tmp/ash-tailscale-systemd-test.ccqAT3`: `smoke.log`,
`platform.txt`, the exact `container-smoke.sh` harness, Dockerfiles, fixture and
source hashes. This container test used root curl supplying trusted headers:
**no Tailscale daemon/proxy, real TLS or browser was tested in this run**.
It does not establish target-host systemd portability. Operators must still
validate their own startup, permissions, cleanup and real Serve/browser boundary.

Formatter setup now imports Ash, Ash Authentication, Plug and Phoenix, with
`Spark.Formatter`, `Phoenix.LiveView.HTMLFormatter`, `remove_parens?: true` and
empty Resource/Domain order config.
A local (not exported) `tailscale: 1` formatter entry covers the library's custom
entity. Sourceror 1.13.0 is dev/test-only; Phoenix is also available in dev/test
so fresh default and test format runs share the same imports. Both fresh-build
formatter checks passed. A reused older build with Spark compiled without
Sourceror needed `mix deps.compile spark --force` once; fresh builds did not.

ExDoc 0.40.4 built HTML/Markdown/EPUB with warnings as errors on both toolchains.
Generated local HTML links/anchors and package contents were inspected. Local
At that stage, `hex.build` succeeded with MIT metadata and only the four existing
production dependencies. The later LiveView milestone adds one **optional**
LiveView requirement, not a mandatory dependency for HTTP-only consumers.
No generated docs are tracked, and no commit, tag, push or publication was made.
Remaining work is owner release review, selecting a real release source ref and
performing any publication explicitly; the license choice is no longer a blocker.

## Credo and workflow preparation

Credo 1.7.19 with AshCredo 0.18.0 passed 94 checks across all 21
library/test/example files with no findings. Shared Leaf opt-ins augment defaults through
`checks.extra` (an `enabled` list alone would replace them), including specs,
module layout, aliases and ten selected Ash checks. No Leaf logger/module-name
relaxations, umbrella paths or custom checks were copied. Leaf's browser-debug
check has no current call sites here; its web authorization check is hard-coded
to `lib/leaf_web/`. Its security principle is relevant, but this small library
does not need a custom linter framework; intentional `authorize?: false` calls
are regression tests, not web authorization bypasses.

Fixes flattened header-parser nesting, added hidden fixture module docs, public
helper specs and callback `@impl` annotations, and aligned declaration/alias order.
No Ash/DSL false positives or check suppressions were needed. The Plug implementation
is unchanged. On Elixir 1.18.4 / OTP 28.5.0.3 and 1.20.4 / OTP 29.1.2,
dev/test formatting and warnings-as-errors compilation, 36 tests + 3 doctests,
docs with warnings as errors and local Hex builds passed. Packages retain only
the four production dependencies at that stage; both lint tools are dev/test-only.
Hex audit was clean.

Actionlint 1.7.12 passed both workflows. Action commit SHAs were verified against
official repository tags; setup-beam's Ubuntu 24.04 OTP/Elixir build listings and
artifact URLs contained both selected pairs. The exact workflow version guard
accepted a matching tag string and rejected mismatched/prefixless strings without
creating any tag. Only the final publishing step's environment receives the Hex
key, after reusable CI and version validation; earlier runner code and locked
build dependencies remain trusted, not isolated from that step. This is local
validation, **not a hosted GitHub Actions
run or publication**. Environment protection/reviewers and secrets still require
owner setup; see [maintenance](maintenance.md).

## Optional root LiveView milestone

The owner chose **permissions until a new logical transport**, with no library
TTL/expiry framework. Same-transport channel rejoin, remount, navigation and patch
retain the original assertion. Open WebSockets can retain stale read/write permissions
indefinitely, including explicitly passed component actors and asynchronous work.
The example keeps revocation-sensitive writes on CSRF-protected HTTP routes. The
subsequent native longpoll extension is recorded below; polling is not reconnecting.

Installed Phoenix 1.8.16 / LiveView 1.2.13 source and upstream Serve v1.94.0 were
reviewed before implementation. Phoenix dispatches upgrades before normal plugs;
`:x_headers` does not include canonical Tailscale headers. The integration therefore
installs a final endpoint `call/2`/`super` wrapper and requires its marker at socket
and root mount validation. It strips incoming reserved-prefix headers, preserves
canonical duplicates/values, and independently requires actual Unix peer metadata.
The marker is a trusted-code installation invariant, not a signature. Later
before-compile overrides/bypassing the final wrapper are unsupported; ordinary
consumer `call/2` overrides are covered by the final wrapper and tested.

The reviewed WebSocket milestone had **53 tests + 3 doctests**, including actual Bandit Unix/TCP
WebSocket HTTP upgrade and Phoenix channel wire messages, not just LiveViewTest:

- Valid origin, session and CSRF upgrade; foreign origin, missing/forged cookie,
  missing/bad CSRF, malformed assertions, duplicates and over-limit login/name reject.
- Internal-prefix spoofing cannot replace canonical assertions or a missing login;
  missing endpoint integration rejects new transports even on Unix. Independent disconnected and
  connected mount tests verify a clear configuration `ArgumentError` from the
  standard hook and a cleared, non-authorizing actor from `assign_actor/1`. The
  real unbridged dead render is generic HTTP 500, not a redirect loop; invalid
  identity still redirects to an ordinary protected HTTP controller route.
  Accidental TCP rejects valid
  CSRF and forged canonical/internal/forwarded headers and `remote_ip`.
- GET identity A / upgrade B uses B, ignoring stale assigns, cookie identity,
  signed page-session identity and browser params. Invalid page tokens reject.
- Real wire rejoin and live-navigation join on one transport retain read/write
  grants; a newly opened WebSocket sees the changed identity/capabilities. These
  assertions model proxy headers; no real grant propagation was measured.
- Root and explicitly supplied LiveComponent actors agree, opaque nested/null JSON
  survives, policy failures deny, and Ash read/create/update/destroy use the actor.
  Static and connected identity rendering escape malicious text.
- The executable example's `/live-demo`, dependency JS asset paths and real
  connected mount pass. The original HTTP/CSRF/security-header suite still passes;
  the example cookie contains only CSRF state. No change to `AshTailscale.Plug`.

On both Elixir 1.18.4 / OTP 28.5.0.3 and Elixir 1.20.4 / OTP 29.1.2,
formatting in dev/test, warnings-as-errors project compilation/tests, all **94
Credo/AshCredo checks across 29 files**, docs with warnings as errors and local Hex
builds pass. `test/http_only.sh` builds a **fresh production consumer** with its own
dependency/build directories and no Phoenix/LiveView modules. It rejects library
compile warnings and exercises the actor builder and HTTP plug; it passes on both
toolchains and is included in the CI docs/package job. The separate fixture Mix
project is explicitly ignored by ExUnit's file discovery, not by Credo.

There is no compile-time LiveView `use` in the library. Plain remote calls remain
available in the optional helper; only absent-optional-module compiler diagnostics
are disabled when LiveView is not installed. With it installed, normal compiler
API checks remain enabled. No conditional module/function framework or linter
suppressions were added. Phoenix LiveView is the sole **optional** package
requirement and supplies Phoenix/HTML transitively; the four mandatory runtime
requirements and dependency lock are unchanged. Removing the unnecessary direct
Phoenix/HTML declarations does not require changing the tested LiveView bound.
Both dev/test formatter imports still work with those transitive dependencies.
Fresh **production consumers with LiveView installed** also compile without library
warnings on both toolchains and exercise the endpoint macro, socket validation,
disconnected/connected mount helpers and HEEx rendering. These are compile/API
smoke checks, not additional proxy/browser tests.

Hook documentation requires running the library hook after other `current_user`
assigners and forbids later identity/session loaders from overwriting it. The
failure destination must be a protected ordinary HTTP controller, never another
LiveView using the hook; the fixtures now use a dedicated controller path. Tests/workflows/build products are not shipped in the archive.

WebSocket milestone correction evidence: `/tmp/ash-ts-liveview-delta-1.20.log`,
`/tmp/ash-ts-liveview-delta-1.18.log`, `/tmp/ash-ts-liveview-prod-1.20.log`,
`/tmp/ash-ts-liveview-prod-1.18.log`, `/tmp/ash_tailscale-liveview-delta-1.20.tar`,
and `/tmp/ash_tailscale-liveview-delta-1.18.tar`. The production-with-LiveView
fixtures are `/tmp/ash-ts-lv-prod-120.qXMoch` and `/tmp/ash-ts-lv-prod-118.8sXnFl`.
Earlier milestone logs remain `/tmp/ash-ts-liveview-final-1.20.log`,
`/tmp/ash-ts-liveview-final-1.18.log`, and `/tmp/ash-ts-liveview-http-only.log`.
Actionlint and diff whitespace checks passed. Hosted Actions had not been run
at this milestone; a later hosted result is recorded below.

**Limits at this milestone:** the wire client is not a browser; browser JS execution,
actual Serve upgrade/header sanitization, real TLS and live grant changes/reconnects
had not yet been validated. Later live evidence is recorded below. The earlier user-reported Tailscale checks and isolated
systemd evidence concern the HTTP/static slice, not this new integration. No host
services, Tailscale configuration or live endpoints were changed. That milestone
was subsequently reviewed and committed through `f72a0c8`; the longpoll and
compatibility follow-ups received separate review, recorded below. No push, tag
or publication was authorized at that milestone.

## Native longpoll fallback extension

The owner approved standard Phoenix fallback while retaining the custom socket's
new-transport authentication gate. Phoenix 1.8.16 generator templates explicitly
configure longpoll with session connect info and `longPollFallbackMs: 2500`; the
example now does that, sharing `:peer_data`, `:x_headers` and session options between
transports. Redundant `check_csrf: true` was removed, **not** Phoenix's default CSRF
validation. The guide is now generated-app deltas rather than repeated session,
CSRF and client boilerplate.

Source review of Phoenix's longpoll transport/server/client established that valid
tokens resume an existing server **before** connect-info extraction or `connect/3`.
The minimal hardening is in the existing endpoint wrapper: strip reserved headers,
then reject any non-Unix peer with generic **actual HTTP 403**, returning the halted
connection without calling `super`. This applies to every request, not just initial
connections. The standalone `AshTailscale.Plug` remains unchanged; ordinary TCP
requests to an endpoint using the optional wrapper now receive 403 rather than the
HTTP plug's later 401. No custom transport, token/signature, identity or TTL system.

Native Phoenix envelope status and HTTP status are distinct:

| Real Unix protocol case | HTTP status | JSON `status` |
| --- | --- | --- |
| New logical transport | 200 | 410 (with new token) |
| Successful push / poll with messages | 200 | 200 |
| Empty poll | 200 | 204 |
| New transport authentication/session/CSRF rejection, or bad origin | 200 | 403 |
| POST with an unusable token | 200 | 410 |

The Unix guard instead returns actual HTTP 403/plain `Forbidden`, before Phoenix
can dispatch/resume. On GET, invalid/foreign tokens can create a **new** transport
when fresh assertions/session/CSRF validate; they do not necessarily hard-fail.

Thirteen additional real Bandit wire tests cover:

- Initial GET/token, empty poll, NDJSON push/replies, header/query token forms,
  origin host/scheme/port on initial and resumed requests, session/CSRF rejection
  on new transports, malformed/duplicate/oversized assertions and reserved-prefix
  spoofing. Responses assert HTTP status separately from JSON envelope status.
- A Unix-issued valid token replayed via accidental TCP for GET/POST/OPTIONS,
  including a valid event push. A test-only outer Plug forges `remote_ip` **before**
  the endpoint; canonical/internal/forwarded headers are also supplied. All fail
  with actual HTTP 403, no event is dispatched, and the original Unix server remains
  usable. This tests resumed tokens, not merely initial TCP connects.
- Initial A and later B headers retain A on polls, pushes, channel rejoin and live
  navigation, including component actors and write permission. A new logical server
  uses B. Normal endpoint shutdown/draining followed by reconnect also gets B.
  Missing later cookies/identity or bad later CSRF does not refresh/reject an already
  valid bearer-token transport: native resumption retains the original authority.
- Invalid/foreign token GETs with valid fresh B credentials create B, never restore
  A; missing session or identity still rejects. Creating a replacement does not
  modify/revoke the original server. The token is Phoenix's native bearer transport
  secret, not a library identity token or a new assertion.
- **UNSAFE configuration reproduction, not a passing security guarantee:** a token
  issued over the bridged Unix endpoint resumes through an **unbridged** endpoint
  sharing signing key/PubSub, even over TCP. Its new connects reject (including
  forged internal headers), but token resumption bypasses that callback. A later
  channel mount still validates the original endpoint/connect info and retains A.
  All HTTP entrypoints capable of resuming that context must enforce the boundary,
  or isolate signing credentials/PubSub. Different-key token reuse is rejected on
  POST; an isolated bridged context can only create a freshly authenticated server
  on GET. The marker does not attest to every poll's entrypoint.
- The executable example enables standard fallback and mounts over native longpoll.
  Existing WebSocket, HTTP, cookie/CSRF, escaping, policy and optional-dependency
  regressions continue to pass. The early custom socket still gates new transports
  before any channel; no upload/transport internals were replaced.

Both supported toolchains pass **66 tests + 3 doctests**, **94 checks across 30
files**, dev/test formatting and forced project warnings-as-errors compilation,
docs warnings-as-errors, local package builds, and fresh HTTP-only and with-LiveView
production consumer checks. Upstream dependency warnings are separated from project
compilation; the library compiles without warnings with or without LiveView.
Actionlint and diff whitespace checks pass. Dependency lock, core HTTP plug and
CI/release workflows are unchanged.

Evidence: `/tmp/ash-ts-longpoll-1.20.log`, `/tmp/ash-ts-longpoll-1.18.log`,
`/tmp/ash_tailscale-longpoll-1.20.tar`, `/tmp/ash_tailscale-longpoll-1.18.tar`.
Fresh with-LiveView fixtures: `/tmp/ash-ts-longpoll-prod-1.20.VjFtKb` and
`/tmp/ash-ts-longpoll-prod-1.18.44e6Xq`.

**Not validated at that stage:** browser JS execution/automatic fallback, real
Serve/TLS, live grant propagation or a new systemd deployment. The later Docker
live run below adds scoped evidence, not a new systemd deployment. Headers are simulated over real
local wire transports; no host services, Tailscale configuration or live endpoints
were changed. At this stage the delta was left uncommitted for independent review;
that review and the later local-commit approval are recorded below. No push, tag
or publication.

### Pre-commit documentation review and in-process test probe

Independent security/code review and a separate full-check rerun signed off the
longpoll code. The documentation now explicitly states that the wrapper makes the
**whole endpoint Unix-only** (including static/public/health routes), and that
**any valid-token holder who can reach the service, including another tailnet user
replaying through Serve, resumes the original actor regardless of current Serve
identity**. Unix ingress is not per-poll human-identity binding.

The ConnTest setup snippet was verified in an isolated consumer at
`/tmp/ash-ts-conn-doc.eoTCUy` with its own normal test dependency `lazy_html 0.1.13`.
That documentation-only probe did not change repository dependencies/lock or code.
Phoenix 1.8.16 `recycle/1` and Plug 1.20.3 test dispatch preserve existing peer data;
fresh `build_conn/0` uses TCP-shaped peer data, and default recycling drops
canonical assertion headers. Applying `ensure_recycled/1` before test peer/header
setup works for initial and subsequent HTTP renders. Unprepared test conns get
403 even for static assets/public health routes. These are simulated adapter tests,
not additional real network-isolation evidence.

**Discovery leading to the reviewed fix below:** ordinary connected LiveViewTest
`live/2` and GET followed by `live/1` initially failed with `FunctionClauseError`
in `Phoenix.LiveView.conn_connect_info/2` for `:session`. The default connect-info
is a `Plug.Conn`; the public accessor does not support `:session`. The library's
redundant mount lookup was wrong, not a missing `lazy_html` installation. LiveView
1.2.13 has no public `put_connect_info/2` API; its private override was not used.
At that stage the guide documented the failure rather than claiming a working
connected recipe. Architecture review then approved removing the redundant lookup
while keeping session/CSRF at the mandatory custom socket gate.

Both supported toolchains ran six isolated checks: four passing HTTP/recycling
cases plus two tests **confirming the expected connected LiveViewTest failures**,
not six successful LiveView integrations. Logs:
`/tmp/ash-ts-conn-doc-final-1.20.log` and `/tmp/ash-ts-conn-doc-final-1.18.log`.
The initial failed probe is `/tmp/ash-ts-conn-doc-1.20.log`. Existing real-wire
coverage remained valid; real Serve/browser/TLS gates were still open at that
probe. No commits were made during it.

### Reviewed standard LiveViewTest compatibility fix

An isolated minimal spike at `/tmp/ash-ts-lvtest-spike.v51pOy/project` passed both
toolchains before repository changes were authorized. The runtime delta deletes
only the mount `valid_session?/1` clause/helper (six lines). The required custom
socket still rejects missing/nil/nonmap sessions and validates marker/Unix peer/
assertions before any channel opens. Phoenix's normal transport session/CSRF
validation remains enabled. Mounts still clear stale actors and independently
validate root topology, integration marker, actual peer and canonical assertions;
they now use only documented peer/header connect-info accessors. No private
accessor/override, broad rescue, test-mode branch or framework fork was added.

Owner approval authorized the normal `{:lazy_html, "~> 0.1.0", only: :test}`
dependency for durable LiveViewTest coverage. The lock adds only `lazy_html 0.1.13`,
`cc_precompiler 0.1.11` and `fine 0.1.6`; existing locked versions are unchanged.
The native parser/build tooling is test-only, not a mandatory runtime requirement.

Six standard LiveViewTest regressions cover ordinary `live/2`, GET then `live/1`,
root/component actors, opaque capabilities, Ash read/create/update/destroy policies,
predicate errors, recycled-connection identity changes and ignored cookie/page/
params/stale-assign identity. Invalid initial peer/assertions and missing bridge
still fail; connected mounts independently reject bad peer/headers even after a
valid HTTP render. Expanded unit cases exercise the actual custom socket's
invalid-session gate and prove failed mount validation clears an authorized stale
actor and prevents an Ash read. Nested/sticky/root and absent-bridge checks remain.

The guide now gives working ConnTest/LiveViewTest recipes, preserving the
whole-endpoint Unix-only rule and explicit any-holder/original-actor bearer-token
warning. Standard LiveViewTest does **not** establish a real transport or validate
wire session/CSRF/Unix isolation; all existing real WebSocket/longpoll/HTTP tests
remain. Native resumption and the unsafe shared-context invariant are unchanged.
The initial failure evidence above is retained as discovery history, not a current
unsupported-feature warning. Final repository validation is recorded separately
below. That implementation stage authorized source changes and validation, not
commits or publication; final review and local-commit approval followed.

Final repository checks pass on both Elixir 1.18.4 / OTP 28.5.0.3 and Elixir 1.20.4 /
OTP 29.1.2: **73 tests + 3 doctests**, all **94 Credo/AshCredo checks across 31
files**, dev/test formatting, forced project warnings-as-errors compilation, docs
warnings-as-errors, local Hex builds, and fresh HTTP-only and with-LiveView
production consumers. Library compilation is warning-free; upstream dependency
warnings are compiled separately. The production-with-LiveView smoke also checks
that `LazyHTML` cannot load. Packaged requirements remain four mandatory plus the
sole optional LiveView dependency; `lazy_html` is not a package runtime requirement.
Actionlint and diff whitespace checks pass. The original HTTP plug, wire tests,
Credo configuration and CI/release workflows are unchanged by this compatibility fix.

Evidence: `/tmp/ash-ts-lvtest-final-1.20.log`, `/tmp/ash-ts-lvtest-final-1.18.log`,
`/tmp/ash_tailscale-lvtest-final-1.20.tar`, `/tmp/ash_tailscale-lvtest-final-1.18.tar`.
Fresh with-LiveView fixtures: `/tmp/ash-ts-lvtest-final-prod-1.20.uk6kox` and
`/tmp/ash-ts-lvtest-final-prod-1.18.VuD9hH`. Final independent security/code and
delta reviews, plus the owner's current validation rerun, passed with no actionable
findings. The reviewed work is recorded in **focused local commits**, not published.
At that point browser JS/automatic fallback, real Serve/TLS, live grant propagation
and hosted Actions remained unvalidated; no host configuration changed. Subsequent
scoped results follow.

## Real Serve HTTPS and operator browser validation

### Launcher, deployment and provenance

The live Docker preparation exposed an actual launcher bug: `examples/serve.exs`
called nonexistent `Phoenix.PubSub.start_link/1`. Earlier wire tests started PubSub
and the endpoint directly, so they did not exercise that script. Commit `1d68de3`
uses public `Supervisor.start_link/2` with PubSub then the endpoint, preserving
preflight/private-Unix, configuration and post-bind checks. Its regression executes
the shipped script in a separate BEAM with owned-process cleanup; it fails with
only the old launcher restored and passes with the fix.

Both local supported toolchains passed **74 tests + 3 doctests**, **94 checks across
31 files**, formatting, warnings-as-errors compilation/docs, package and fresh
consumer checks. Separately, the orchestrator verified hosted GitHub Actions run
[41053692144](https://github.com/leaf-insurance/ash_tailscale/actions/runs/41053692144)
was **successful for `dd5125a`**. That is not hosted-CI evidence for the later
launcher fix or these documentation changes.

The Docker image was built from archived `dd5125a` plus the reviewed launcher patch;
all 50 tracked source files were verified equivalent to `1d68de3`. It was not
retroactively relabelled as built from a different input. This was a `MIX_ENV=test`
example deployment, not a production release/systemd test:

- Tailscale **1.104.2**, Elixir **1.18.4 / OTP 28.5.0.8**, locked Phoenix **1.8.16** /
  LiveView **1.2.13**; verified-TLS client Python **3.14.8** / OpenSSL **3.5.9**.
- Nonroot app, network-none, private directory **0700** / socket **0600**, runtime-only
  private secret; userspace Tailscale in a separate container with bridge egress
  and a read-only shared socket volume. Its sole added capability was DAC_OVERRIDE.
  No published ports, host network/binds, TUN, NET_ADMIN, privileged mode or
  seccomp-unconfined. Local smoke also checked unrelated-UID socket denial.
- Owner-controlled grants and container-only Serve; no host Serve/service changes,
  unverified-CA installation or disabled TLS verification.

### Actual HTTPS wire checks: 35 granted + 35 revoked

The implementation agent ran the granted phase. After the owner explicitly
confirmed read/write actions `[]` with TCP443 retained, the orchestrator ran the
revoked phase. **Both passed 35 checks**, using real Serve HTTPS with certificate
and hostname verification and **TLS1.3**. The script offers only ALPN `http/1.1`
and sends HTTP/1.1. It is not browser automation or evidence of frontend HTTP/2.

| Case | Granted phase | Revoked phase |
| --- | --- | --- |
| Fresh HTTP page/session | 200, expected displayed identity, CSRF markup, Secure/HttpOnly `__Host-` cookie, Path=/, no Domain | Same setup; initial Read forbidden |
| Form using fresh cookie/CSRF | 200, echoed login matches expected baseline | 403, **status only** |
| Missing/bad form CSRF | 403 against the successful 200 control | 403, not a discriminating control in this phase |
| Fresh WebSocket + signed-page join/read | 101, connected Read allowed | 101, connected Read forbidden |
| Fresh native longpoll + signed-page join/read | HTTP200 / JSON410, connected Read allowed | HTTP200 / JSON410, connected Read forbidden |
| Missing/forged cookie, missing/bad CSRF, wrong origin host/scheme/port | Seven negatives per transport: WS403; LP HTTP200 / JSON403 | Same negative statuses |

Five spoof variants covered canonical login/name/profile headers, internal reserved
identity headers, canonical capabilities, internal capabilities and combined
identity/capabilities. Each was tested on HTTP and **fresh WS/LP connected mounts**
from ordinary signed pages/sessions. Transport spoof headers were placed on the
upgrade or initial LP request, not merely inferred from HTTP sanitization; later
LP pushes/polls used the established transport. Display identity and read state
were parsed from connected join replies, with read-event acknowledgements checked.

Forged **EMPTY** capabilities did not strip actual read/write access in phase one.
With actual grants removed, forged **FULL** capabilities did not restore connected
WS/LP reads: **Read forbidden was directly observed**. HTTP attempts remained403,
but their bodies were **not asserted**: this is consistent with policy denial,
not independent discrimination from CSRF/session failure. The granted200 versus
missing/bad-CSRF403 control establishes HTTP CSRF evidence; revoked HTTP CSRF
cases are non-discriminating. No successful create response occurred in the
revoked phase; storage side effects were not independently audited.

The UI preserves visible name-or-login, but when the actual display name is kept,
**hidden connected LOGIN and raw profile are not directly observed**. HTTP echoed
login and the shared bridge support the interpretation, not direct proof of those
hidden fields. No debug endpoint or transport/authentication bypass was added.

### Operator browser reports and remaining scope

Owner reports used **Firefox157.0, 64-bit, NixOS**; these are human observations,
separate from the automated wire checks. Browser frontend HTTP version was not
explicitly recorded, so there is no specific HTTP/2 claim.

- Own displayed identity/ReadAllowed, WebSocket101 and a read click with Phoenix
  event/read and `phx_reply` status ok frames. An acknowledgement alone is not a
  policy result.
- WebSocket grant removal: old transport remained Allowed; new tab/reload became
  Forbidden. Restoration: an already-denied transport remained Denied until reload
  became Allowed, consistent with logical-transport snapshots.
- Orchestrator temporarily served text at `/live/websocket`, leaving the root Unix
  proxy/capability forwarding unchanged. Owner observed failed WS attempts,
  **automatic native-longpoll fallback**, working read clicks, retained old-poll
  authority and fresh-transport denial after revocation. ReadForbidden was an
  application result, not an HTTP error.
- The temporary route was removed and Serve JSON asserted exactly equal to its
  saved baseline. Owner confirmed a fresh private window recovered ReadAllowed
  and WebSocket101. This does **not** complete the unconfirmed old-denied-LP-transport
  restoration matrix or establish final grant restoration after the revoked run.

Read-only evidence review signed off with the HTTP status-only and hidden-field
limits above; no rerun was required. Tagged-client testing in **this deployment
was intentionally deferred by owner choice**. Earlier HTTP-slice tagged-client
reports are separate, not current-deployment evidence. No full two-user
cookie-attack simulation, broad browser/server matrix or new systemd portability
claim is made. Publication remains a separate gate.

Sanitized scripts/results are retained under `/tmp/ash-ts-live.cteVXm`:
`REAL_HTTPS_VALIDATION.md`, `real_https_validation.py`, `real-https-granted.json`
and `real-https-revoked.json`. Cookies, CSRF/page/native transport tokens stayed in
memory; no raw secret values are recorded here. Client sockets were closed and
own LP servers left to native idle expiry. Source/library/tests were unchanged by
live validation.

**Cleanup completed (orchestrator-confirmed):** after checking the harness labels,
the exact two containers and three named volumes (socket, app state, Tailscale
state) were removed, the app image deleted and the harness Tailscale image alias
removed. No harness containers, volumes or image tags remain; **both services are
stopped**. Unrelated containers, shared/upstream images and earlier systemd/base
caches were retained; no global prune or host service changes. Sanitized `/tmp`
evidence remains. No logout, remote node deletion or tailnet-policy removal was
performed by agents; the owner handles remote Tailscale cleanup. Final grant
restoration was not confirmed and was not required for this authorized teardown.
