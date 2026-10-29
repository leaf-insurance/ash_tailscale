# Local example launcher, not a release/service manager.
# Requires an already-created app-owned 0700 directory and shell umask 0077.
socket = System.fetch_env!("TS_SOCKET_PATH")
host = System.fetch_env!("TS_HOST")
secret = System.fetch_env!("SECRET_KEY_BASE")
AshTailscale.Example.check_directory!(Path.dirname(socket))

unless Path.type(socket) == :absolute and byte_size(secret) >= 64 do
  raise "require an absolute socket path and a >=64-byte secret"
end

unless File.lstat(socket) == {:error, :enoent} do
  raise "socket path exists; stop the previous server before removing a stale socket"
end

Application.put_env(
  :ash_tailscale,
  AshTailscale.Example.Endpoint,
  AshTailscale.Example.config(socket, host, secret)
)

{:ok, _} = AshTailscale.Example.Endpoint.start_link()
{:ok, {:local, ^socket}} = Bandit.PhoenixAdapter.server_info(AshTailscale.Example.Endpoint, :http)
File.chmod!(socket, 0o600)
# Keep the endpoint's parent alive; a consumer supervises it in its application.
Process.sleep(:infinity)
