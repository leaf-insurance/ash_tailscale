defmodule AshTailscale.CapabilityCheckTest do
  use ExUnit.Case, async: true
  alias AshTailscale.CapabilityCheck, as: Check

  def echo(caps, pid, value) do
    send(pid, {:called, caps})
    value
  end

  def fail(_, :raise), do: raise("predicate failure")
  def fail(_, :throw), do: throw(:failure)
  def fail(_, :exit), do: exit(:failure)

  test "passes the entire map unchanged and only literal true authorizes" do
    caps = %{"null" => nil, "unknown" => [%{"nested" => false}]}
    actor = AshTailscale.test_actor!("alice", caps)

    for value <- [true, false, nil, :yes, 1, "true", [], %{}, {:ok, true}, {:error, :bad}] do
      opts = [predicate: {__MODULE__, :echo, [self(), value]}]
      assert Check.match?(actor, %{}, opts) == (value === true)
      assert_received {:called, ^caps}
    end
  end

  test "nil, unrelated, unmarked and invalid actors cannot invoke the predicate" do
    for actor <- [
          nil,
          %{},
          %{login: "alice", capabilities: %{}},
          %AshTailscale.User{login: "alice", capabilities: %{}},
          AshTailscale.test_actor!("alice") |> Map.put(:login, ""),
          AshTailscale.test_actor!("alice") |> Map.put(:capabilities, nil)
        ] do
      refute Check.match?(actor, %{}, predicate: {__MODULE__, :echo, [self(), true]})
      refute_received {:called, _}
    end
  end

  test "predicate failures and missing functions deny rather than escaping" do
    actor = AshTailscale.test_actor!("alice")

    for failure <- [:raise, :throw, :exit] do
      refute Check.match?(actor, %{}, predicate: {__MODULE__, :fail, [failure]})
    end

    refute Check.match?(actor, %{}, predicate: {__MODULE__, :missing, []})
    assert {:error, _} = Check.init(predicate: fn _ -> true end)
    assert {:error, _} = Check.init([])
  end
end
