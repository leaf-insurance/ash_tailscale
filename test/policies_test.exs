defmodule AshTailscale.PoliciesTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  alias AshTailscale.Example.Report

  defp actor(actions) do
    AshTailscale.test_actor!("alice", %{"example.com/cap/reports" => [%{"actions" => actions}]})
  end

  test "a denied simple check alone returns Forbidden on a real Ash read" do
    writer = actor(["write"])
    assert {:ok, report} = Ash.create(Report, %{title: "A"}, actor: writer)
    reader = actor(["read"])
    assert {:ok, [%{id: id}]} = Ash.read(Report, actor: reader)
    assert id == report.id

    for denied <- [writer, actor([]), nil, %{}, %AshTailscale.User{login: "alice"}] do
      assert {:error, %Ash.Error.Forbidden{}} = Ash.read(Report, actor: denied)
    end
  end

  test "consumer row-filter policies can produce empty results instead of Forbidden" do
    query =
      AshTailscale.FilteredRead
      |> Ash.Query.for_read(:read)
      |> Ash.DataLayer.Simple.set_data([%AshTailscale.FilteredRead{title: "private"}])

    assert {:ok, [_]} = Ash.read(query, actor: actor(["read"]))
    assert {:ok, []} = Ash.read(query, actor: actor([]))
    assert {:ok, []} = Ash.read(query, actor: nil)
  end

  test "real Ash create/update/destroy policies fail closed" do
    writer = actor(["write"])
    reader = actor(["read"])
    assert {:ok, report} = Ash.create(Report, %{title: "A"}, actor: writer)
    assert {:error, %Ash.Error.Forbidden{}} = Ash.create(Report, %{title: "B"}, actor: reader)
    assert {:error, %Ash.Error.Forbidden{}} = Ash.create(Report, %{title: "B"}, actor: nil)
    assert {:error, %Ash.Error.Forbidden{}} = Ash.update(report, %{title: "B"}, actor: reader)
    assert {:ok, updated} = Ash.update(report, %{title: "B"}, actor: writer)
    assert updated.title == "B"
    assert {:error, %Ash.Error.Forbidden{}} = Ash.destroy(updated, actor: reader)
    assert :ok = Ash.destroy(updated, actor: writer)
  end

  test "Serve-shaped multi-entry grants authorize real reads and writes without merging entries" do
    caps = %{
      "example.com/cap/reports" => [
        nil,
        %{"actions" => ["read"]},
        %{"actions" => ["write"]},
        %{"actions" => "invalid"}
      ]
    }

    actor = AshTailscale.test_actor!("alice", caps)
    assert {:ok, report} = Ash.create(Report, %{title: "Serve-shaped grant"}, actor: actor)
    assert {:ok, [%{id: id}]} = Ash.read(Report, actor: actor)
    assert id == report.id

    for value <- [
          nil,
          [],
          [nil, 1, %{"actions" => nil}],
          [%{"actions" => ["wr"]}, %{"actions" => ["ite"]}]
        ] do
      denied = AshTailscale.test_actor!("alice", %{"example.com/cap/reports" => value})

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.create(Report, %{title: "denied"}, actor: denied)
    end
  end

  test "same login on independent requests has no shared capabilities" do
    assert {:ok, _} = Ash.create(Report, %{title: "A"}, actor: actor(["write"]))
    assert {:ok, [_]} = Ash.read(Report, actor: actor(["read"]))
    assert {:error, %Ash.Error.Forbidden{}} = Ash.read(Report, actor: actor([]))

    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.read(Report, actor: AshTailscale.test_actor!("alice"))
  end
end
