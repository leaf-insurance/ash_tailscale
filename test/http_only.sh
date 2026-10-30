#!/usr/bin/env bash
# Fresh consumer dependency graph/build: repository Phoenix beams must not leak in.
set -euo pipefail
export ASH_TAILSCALE_PATH="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/ash-ts-http-only.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
cp "$ASH_TAILSCALE_PATH/test/fixtures/http_only/mix.exs" "$tmp/mix.exs"
cp "$ASH_TAILSCALE_PATH/mix.lock" "$tmp/mix.lock"
cd "$tmp"
unset MIX_BUILD_PATH MIX_DEPS_PATH
export MIX_ENV=prod
mix deps.get --check-locked
mix deps.compile
# Separate upstream warnings from warnings in this library without Phoenix present.
mix deps.compile ash_tailscale --force 2>&1 | tee "$tmp/library-compile.log"
if grep -q 'warning:' "$tmp/library-compile.log"; then
  echo 'HTTP-only library compilation emitted warnings' >&2
  exit 1
fi
mix compile --warnings-as-errors
mix run -e '
  for module <- [Phoenix, Phoenix.LiveView, Phoenix.Component, Phoenix.HTML] do
    false = Code.ensure_loaded?(module)
  end
  {:ok, actor} = AshTailscale.from_headers([{"tailscale-user-login", "http-only"}])
  "http-only" = actor.login
  conn = Plug.Test.conn(:get, "/")
  conn = Plug.Test.put_peer_data(conn, %{address: {:local, ""}, port: 0, ssl_cert: nil})
  conn = Plug.Conn.put_req_header(conn, "tailscale-user-login", "http-only")
  conn = AshTailscale.Plug.call(conn, [])
  false = conn.halted
  "http-only" = Ash.PlugHelpers.get_actor(conn).login
  IO.puts("HTTP_ONLY_WITHOUT_PHOENIX_OR_LIVE_VIEW_PASS")
'
