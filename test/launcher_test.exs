defmodule AshTailscale.LauncherTest do
  use ExUnit.Case, async: true
  import Bitwise

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
