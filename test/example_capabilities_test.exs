defmodule AshTailscale.ExampleCapabilitiesTest do
  use ExUnit.Case, async: true
  alias AshTailscale.Example.Capabilities

  test "consumer handles Serve arrays/null and evaluates each entry independently" do
    caps = %{"example.com/cap/reports" => [%{"actions" => ["read"]}, %{"actions" => ["write"]}]}
    assert Capabilities.allowed?(caps, "read")
    assert Capabilities.allowed?(caps, "write")
    refute Capabilities.allowed?(caps, "delete")

    refute Capabilities.allowed?(%{}, "read")

    for entries <- [
          nil,
          [],
          false,
          1,
          "write",
          %{"actions" => ["write"]},
          [nil, false, 1, [], %{}, %{"actions" => nil}, %{"actions" => "write"}],
          [%{"actions" => ["wr"]}, %{"actions" => ["ite"]}]
        ] do
      refute Capabilities.allowed?(%{"example.com/cap/reports" => entries}, "write")
    end

    assert Capabilities.allowed?(
             %{
               "example.com/cap/reports" => [nil, %{"actions" => nil}, %{"actions" => ["write"]}]
             },
             "write"
           )
  end
end
