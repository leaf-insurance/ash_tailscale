# Maintainer checks and releases

Repository tooling, not consumer setup. See [validation](validation.md) for
recorded runtime/security evidence and limitations.

## Local checks

Credo and AshCredo are dev/test-only, checking `lib/`, `test/` and `examples/`.
The shared Leaf opt-ins (specs, module layout, aliases and others) augment Credo
defaults via `checks.extra`; ten selected Ash checks are explicitly enabled.
Other opinionated Ash checks retain the plugin's disabled defaults. Compile in
`MIX_ENV=test` first so Ash checks can inspect actual example/resource metadata.
Keep findings actionable, not hidden by authentication-module exclusions.

```sh
mix deps.get --check-locked
mix deps.compile
mix compile --warnings-as-errors
mix format --check-formatted
MIX_ENV=test mix deps.compile
MIX_ENV=test mix compile --warnings-as-errors
MIX_ENV=test mix format --check-formatted
MIX_ENV=test mix credo --strict
mix test --warnings-as-errors
mix docs --warnings-as-errors
mix hex.build --output /tmp/ash_tailscale-check.tar
bash test/http_only.sh
```

Compile dependencies separately: upstream optional-tool/deprecation warnings
are not project warnings. When switching Elixir/OTP locally, use separate
absolute `MIX_BUILD_PATH` and compatible Hex/Rebar installations; a Hex archive
compiled with newer Elixir can fail on the older toolchain. The HTTP-only check
uses a fresh temporary dependency/build directory (removed on exit), the repository
lock, and the active toolchain/Hex installation. It rejects library compile warnings
and asserts that no Phoenix/LiveView modules can load before exercising the HTTP plug.

## GitHub Actions

- `.github/workflows/ci.yml`: pushes to `main`, PRs targeting `main`, and reusable
  calls. Tests/format/strict Credo run on Elixir 1.18.4 / OTP 28.5.0.3 and
  Elixir 1.20.4 / OTP 29.1.2; a dev job compiles, formats, builds docs with warnings
  as errors, builds a local Hex archive, and compiles/runs a fresh HTTP-only
  production consumer with no Phoenix/LiveView present. All use Ubuntu 24.04.
- Dependency/build cache keys include OS/architecture, exact installed toolchain,
  Mix environment and lockfile hash. Restore prefixes never cross toolchains or
  environments; dependency fetching still checks the lock.
- Actions are pinned to verified full commit SHAs with version comments.
  Workflow tokens have only `contents: read`; checkouts do not persist credentials.
  PR checks receive no publishing key. No real Tailscale deployment is exercised.

## Authorized releases only

`.github/workflows/publish.yml` runs on pushed `v*` tags. It runs the **same CI
on that tag**, then requires the tag to equal `v<version from mix.exs>` exactly.
Only after those gates does it publish package/docs with `mix hex.publish --yes`.
Runs for the same tag are serialized, not cancelled midway. There is no branch
ancestry restriction or version-bumping/tag-creation automation.

Before enabling publication, the owner must configure the `hex-publish` GitHub
environment with required reviewers and appropriate deployment rules, and add a
least-privilege/package-scoped `HEX_API_KEY` environment secret. **Naming an
environment in YAML does not itself enforce approval**; configure and verify
those protections before adding the key. Only the final step's environment
receives `HEX_API_KEY`. This is **not isolation from earlier code on that runner**:
checked-out code and locked build dependencies remain trusted, can alter the
runner, and `hex.publish` may compile/run ExDoc while the key is present.
This setup does not create environments, secrets, tags or releases for you.

Release docs receive `ASH_TAILSCALE_SOURCE_REF` from the validated real tag;
ordinary/local docs default to `main`. No future tag is invented.

Before authorizing a release tag:
- Set/review the package version and update the README's pending/Git-preview
  installation wording for the authorized release **before publication**.
- Run the checks above and inspect the package contents and release documentation.
- Verify environment approvals/key permissions, then authorize only the exact
  matching tag, knowing that pushing it requests publication.

The current README remains unreleased; adding these workflows does not publish it.
