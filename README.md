# AshTailscale

Use Tailscale identity and capabilities as Ash actors in your existing Phoenix
LiveView application. No accounts table, provisioning or session identity:
AshTailscale supplies a transient actor; your resource policies decide access.

## Install

The first Hex release is not published. Add the Git dependency and commit your
lockfile:

```elixir
{:ash_tailscale, github: "leaf-insurance/ash_tailscale", branch: "main"}
```

Run `mix deps.get`. Requires Elixir 1.18+; existing LiveView must satisfy
`~> 1.2.13`. LiveView remains an optional package dependency for HTTP-only users.

## Set up LiveView

**Start with the [LiveView guide](docs/live_view.md).** It adds the endpoint bridge,
required socket, HTTP plug, mount hook and capability policies to your working app.
Then follow the short [Unix socket + Serve recipe](docs/deployment.md).

The whole endpoint must be private Unix-only behind trusted Tailscale Serve.
Connected permissions are a transport snapshot, not continuously refreshed grants;
the guide explains when to use fresh HTTP requests instead.

## HTTP-only apps

Use the same deployment boundary, add `AshTailscale.Plug` after existing browser
session/CSRF protection, and pass `actor: Ash.PlugHelpers.get_actor(conn)` to Ash.
See the plug API and the guide's [capability policy](docs/live_view.md#3-authorize-ash-actions).
You can omit the LiveView bridge/socket/hook and dependency.

## References

[Testing](docs/testing.md) · [Optional systemd setup](docs/systemd.md) ·
[Design](https://github.com/leaf-insurance/ash_tailscale/blob/main/docs/design.md) ·
[Validation evidence](https://github.com/leaf-insurance/ash_tailscale/blob/main/docs/validation.md) ·
[MIT license](https://github.com/leaf-insurance/ash_tailscale/blob/main/LICENSE)
