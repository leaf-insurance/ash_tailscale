# Maintainer validation record

This is maintainer evidence, not the consumer setup guide or a promise of general
production readiness. Start with [README](../README.md) and [setup](deployment.md).
The internal [design](design.md) retains research references and scope decisions.
[Maintainer commands and workflows](maintenance.md) cover local checks and release gates.

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
browser/server version matrix was supplied.

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
**not a complete two-user privilege-escalation attack simulation**. The named
browser/version matrix, broader server/platform coverage and tagged-client native
DNS remain gaps. New environments must rerun the smoke checks, including their
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

The owner chose **permissions until a new actual WebSocket connection**, with no
TTL/expiry framework. Same-transport channel rejoin, remount, navigation and patch
retain the original assertion. Read and write permissions can remain stale
indefinitely, including explicitly passed component actors and asynchronous work.
The example keeps revocation-sensitive writes on CSRF-protected HTTP routes.

Installed Phoenix 1.8.16 / LiveView 1.2.13 source and upstream Serve v1.94.0 were
reviewed before implementation. Phoenix dispatches upgrades before normal plugs;
`:x_headers` does not include canonical Tailscale headers. The integration therefore
installs a final endpoint `call/2`/`super` wrapper and requires its marker at socket
and root mount validation. It strips incoming reserved-prefix headers, preserves
canonical duplicates/values, and independently requires actual Unix peer metadata.
The marker is a trusted-code installation invariant, not a signature. Later
before-compile overrides/bypassing the final wrapper are unsupported; ordinary
consumer `call/2` overrides are covered by the final wrapper and tested.

The expanded suite is **53 tests + 3 doctests**, including actual Bandit Unix/TCP
WebSocket HTTP upgrade and Phoenix channel wire messages, not just LiveViewTest:

- Valid origin, session and CSRF upgrade; foreign origin, missing/forged cookie,
  missing/bad CSRF, malformed assertions, duplicates and over-limit login/name reject.
- Internal-prefix spoofing cannot replace canonical assertions or a missing login;
  missing endpoint integration rejects even on Unix. Independent disconnected and
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

Latest correction evidence: `/tmp/ash-ts-liveview-delta-1.20.log`,
`/tmp/ash-ts-liveview-delta-1.18.log`, `/tmp/ash-ts-liveview-prod-1.20.log`,
`/tmp/ash-ts-liveview-prod-1.18.log`, `/tmp/ash_tailscale-liveview-delta-1.20.tar`,
and `/tmp/ash_tailscale-liveview-delta-1.18.tar`. The production-with-LiveView
fixtures are `/tmp/ash-ts-lv-prod-120.qXMoch` and `/tmp/ash-ts-lv-prod-118.8sXnFl`.
Earlier milestone logs remain `/tmp/ash-ts-liveview-final-1.20.log`,
`/tmp/ash-ts-liveview-final-1.18.log`, and `/tmp/ash-ts-liveview-http-only.log`.
Actionlint and diff whitespace checks pass. Hosted Actions have not been run.

**Limits:** the wire client is not a browser; browser JS execution, actual Serve
upgrade/header sanitization, real TLS and live grant changes/reconnects still need
operator validation. The earlier user-reported Tailscale checks and isolated
systemd evidence concern the HTTP/static slice, not this new integration. No host
services, Tailscale configuration or live endpoints were changed. No new commit,
push, tag or publication is authorized by this validation; independent review is
still required.
