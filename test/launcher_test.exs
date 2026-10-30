defmodule AshTailscale.LauncherTest do
  use ExUnit.Case, async: true
  import Bitwise
  alias AshTailscale.Test.WebSocketClient, as: Client

  test "actual launcher script starts the private Unix endpoint in a separate BEAM" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "ash-ts-entry-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    on_exit(fn -> File.rm_rf!(dir) end)
    socket = Path.join(dir, "http.sock")

    # Execute the shipped script, not another copy of its startup sequence. Stdin
    # stops only this child VM; EOF also stops it if the test/port owner dies.
    boot = """
    Application.put_all_env(Config.Reader.read!("config/config.exs", env: :test))
    {:ok, _} = Application.ensure_all_started(:ash_tailscale)
    Logger.configure(level: :error)
    spawn_link(fn -> Code.require_file("examples/serve.exs") end)
    IO.gets("")
    System.halt(0)
    """

    env = [
      {~c"TS_SOCKET_PATH", String.to_charlist(socket)},
      {~c"TS_HOST", ~c"launcher.example.test"},
      {~c"SECRET_KEY_BASE", String.to_charlist(String.duplicate("launcher-test-only-", 4))},
      {~c"ERL_FLAGS", ~c"+S 2:2"}
    ]

    port =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [
          "-c",
          ~s(umask 077; exec "$@"),
          "launcher-test",
          System.find_executable("elixir"),
          "-pa",
          Path.join(Mix.Project.build_path(), "lib/*/ebin"),
          "-e",
          boot
        ],
        env: env
      ])

    try do
      await_socket(port, socket, 150)
      assert (File.stat!(dir).mode &&& 0o777) == 0o700
      assert (File.stat!(socket).mode &&& 0o777) == 0o600
      headers = [{"host", "launcher.example.test"}, {"x-forwarded-proto", "https"}]
      assert Client.request(socket, "/", headers).status == 401

      headers = [{"tailscale-user-login", "launcher@example.test"} | headers]
      response = Client.request(socket, "/", headers)
      assert response.status == 200
      assert response.body =~ "launcher@example.test"
      assert response.body =~ ~s(name="csrf-token")
      assert response.headers["set-cookie"] =~ "__Host-tailscale_example="
      assert response.headers["set-cookie"] =~ "secure"
      assert response.headers["set-cookie"] =~ "HttpOnly"
      assert Client.request(socket, "/live-demo", headers).status == 200
    after
      if Port.info(port) do
        Port.command(port, "stop\n")
        assert_receive {^port, {:exit_status, 0}}, 5000
      end
    end
  end

  test "launcher requires an effective-user-owned private directory, not a symlink" do
    dir = Path.join(System.tmp_dir!(), "ash-ts-launch-#{System.unique_integer([:positive])}")
    File.mkdir!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    File.chmod!(dir, 0o700)
    assert :ok = AshTailscale.Example.check_directory!(dir)

    File.chmod!(dir, 0o755)

    assert_raise RuntimeError, ~r/owned by the effective OS user/, fn ->
      AshTailscale.Example.check_directory!(dir)
    end

    File.chmod!(dir, 0o700)
    link = Path.join(dir, "link")
    File.ln_s!(dir, link)
    assert_raise RuntimeError, fn -> AshTailscale.Example.check_directory!(link) end
  end

  defp await_socket(port, socket, attempts) when attempts > 0 do
    receive do
      {^port, {:exit_status, status}} ->
        flunk("launcher exited before binding its Unix socket (status #{status})")
    after
      100 ->
        case File.stat(socket) do
          {:ok, %{mode: mode}} when (mode &&& 0o777) == 0o600 -> :ok
          _ -> await_socket(port, socket, attempts - 1)
        end
    end
  end

  defp await_socket(_port, _socket, 0), do: flunk("launcher did not bind its Unix socket")

  # Read-only ownership fixture, available on this Linux host. Do not chown anything
  # or require privileged execution just to construct an owner-mismatch fixture.
  {uid, 0} = System.cmd("id", ["-u"])
  uid = String.to_integer(String.trim(uid))

  @foreign_owner_fixture (case File.lstat("/root") do
                            {:ok, stat} ->
                              stat.uid != uid and stat.type == :directory and
                                (stat.mode &&& 0o777) == 0o700

                            _ ->
                              false
                          end)

  @tag skip: not @foreign_owner_fixture
  test "launcher rejects a foreign-owned 0700 directory" do
    assert_raise RuntimeError, ~r/owned by the effective OS user/, fn ->
      AshTailscale.Example.check_directory!("/root")
    end
  end
end
