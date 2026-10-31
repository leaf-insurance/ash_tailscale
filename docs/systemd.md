# Optional Linux/systemd reference

For an existing production release, root-owned tailscaled and the
[Unix endpoint configuration](deployment.md). This is one lifecycle recipe, not
a requirement of AshTailscale. Replace the release name and Serve hostname.

## Install the release

Build for the target OS/architecture. These are first-install commands; stop an
existing service before replacing its release. Keep code root-owned and do not
embed secrets. The release COOKIE stays root-only:

```sh
MIX_ENV=prod mix release
sudo install -d -m0700 /opt/reports
sudo cp -a _build/prod/rel/REPLACE_WITH_RELEASE_NAME/. /opt/reports/
sudo chown -R root:root /opt/reports
sudo chmod 0600 /opt/reports/releases/COOKIE
sudo find /opt/reports ! -path /opt/reports/releases/COOKIE -exec chmod u=rwX,go=rX {} +
```

## Private environment

Create once; keep values stable across restarts. PID 1 reads this root:root **0600** file.
The independent `RELEASE_COOKIE` lets DynamicUser run without reading/writing the
root-owned release cookie file:

```sh
sudo install -o root -g root -m0600 /dev/null /etc/reports.env
sudo sh -ec '
  secret=$(openssl rand -hex 64)
  cookie=$(openssl rand -hex 32)
  printf "TS_HOST=REPLACE_WITH_SERVE_HOSTNAME\nSECRET_KEY_BASE=%s\nRELEASE_COOKIE=%s\n" "$secret" "$cookie" > /etc/reports.env
'
sudoedit /etc/reports.env
```

Use the actual Serve HTTPS hostname. Do not regenerate or print these secrets on
each start, commit them, or put them in the release image.

## Install the unit

Install the [example unit](https://github.com/leaf-insurance/ash_tailscale/blob/main/examples/systemd/reports.service)
and replace its release binary name:

```sh
sudo install -m0644 deps/ash_tailscale/examples/systemd/reports.service /etc/systemd/system/reports.service
sudoedit /etc/systemd/system/reports.service
sudo systemctl daemon-reload
sudo systemctl enable --now reports.service
```

The unit supplies:
- `DynamicUser=yes`, app-owned **0700** `/run/reports`, umask **0077** (socket **0700**).
- `TS_SOCKET_PATH=/run/reports/phoenix.sock`, a writable working directory and
  `RELEASE_TMP` there for release temporary files.
- Foreground `bin/RELEASE_NAME start`; no Mix server or daemon mode.
- `RuntimeDirectoryPreserve=no` and `Restart=on-failure`: stopped-service directory/
  socket cleanup and automatic restart, without stale-socket unlink hooks.

Reserve the service identity and runtime directory **exclusively for this unit**;
no second app/manual process. Root tailscaled can traverse it. Persistent app data
needs separate managed storage, not this disposable directory. The unit does not
remove generated Phoenix TCP listeners: apply the deployment configuration first.
EPMD/distribution and other release-management interfaces remain your responsibility.

## Verify

```sh
systemctl status reports
journalctl -u reports
systemctl show reports -p MainPID --value
sudo ss -xlpn
sudo stat -c '%a %n' /run/reports /run/reports/phoenix.sock
sudo ss -ltnp
```

Check that the expected BEAM owns the Unix listener, permissions are private and
there is no Phoenix HTTP TCP listener. Test stop/restart on your target system.
Configure [grants and Serve](deployment.md#2-grant-and-serve) separately as an
authorized operator—not from an unprivileged ExecStartPost.

An isolated systemd lifecycle test is recorded in
[validation](https://github.com/leaf-insurance/ash_tailscale/blob/main/docs/validation.md);
it is not a portability guarantee or a substitute for your real Serve/TLS checks.
