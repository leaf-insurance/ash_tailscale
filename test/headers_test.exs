defmodule AshTailscale.HeadersTest do
  use ExUnit.Case, async: true

  defp build(headers),
    do: AshTailscale.from_headers([{"tailscale-user-login", "Alice"} | headers])

  test "login is preserved; missing and empty profile fields normalize to nil" do
    assert {:ok, actor} = build([])
    assert actor.login == "Alice"
    assert actor.name == nil
    assert actor.profile_pic == nil
    assert actor.capabilities == %{}
    assert {:ok, actor} = build([{"tailscale-user-name", ""}, {"tailscale-user-profile-pic", ""}])
    assert actor.name == nil
    assert actor.profile_pic == nil
    assert {:ok, actor} = AshTailscale.from_headers([{"Tailscale-User-Login", " Alice "}])
    assert actor.login == " Alice "
  end

  test "capabilities are opaque JSON with arbitrary nested values and nulls" do
    caps = %{
      "anything" => nil,
      "scalar" => 12.5,
      "bool" => false,
      "string" => "日本語",
      "encoded-looking-data" => "=?utf-8?q?literal?=",
      "malformed-looking-data" => "=?this is still ordinary JSON",
      "list" => [nil, 1, "x", %{"nested" => [true, nil]}],
      "object" => %{"not-actions" => %{"deep" => nil}}
    }

    assert {:ok, actor} = build([{"tailscale-app-capabilities", Jason.encode!(caps)}])
    assert actor.capabilities === caps
    refute Map.has_key?(actor.capabilities, "missing")
  end

  test "missing, empty, whitespace, malformed and duplicate identity fails closed" do
    for headers <- [
          [],
          [{"tailscale-user-name", "Alice"}],
          [{"tailscale-app-capabilities", "{}"}],
          [{"tailscale-user-login", ""}],
          [{"tailscale-user-login", " "}],
          [{"tailscale-user-login", "=?utf-8?q?___?="}],
          [{"tailscale-user-login", <<255>>}],
          [{"tailscale-user-login", "a\r\nb"}],
          [{"tailscale-user-login", "a"}, {"Tailscale-User-Login", "b"}],
          [{"tailscale-user-login", nil}],
          %{"tailscale-user-login" => "a"},
          [nil]
        ] do
      assert {:error, :invalid_headers} = AshTailscale.from_headers(headers)
    end
  end

  test "invalid JSON and non-object capability values are rejected, not replaced by empty maps" do
    for value <- ["", "{", "[]", "null", "true", "1", "\"text\"", "{\"x\":NaN}", <<255>>] do
      assert {:error, _} = build([{"tailscale-app-capabilities", value}])
    end

    assert {:error, _} =
             build([{"tailscale-app-capabilities", "{}"}, {"tailscale-app-capabilities", "{}"}])
  end

  test "RFC2047 UTF-8 Q and B, encoded underscores, and multiword concatenation" do
    assert {:ok, actor} =
             build([
               {"tailscale-user-name", "=?UTF-8?Q?Ren=C3=A9_=5F?= =?utf-8?q?__Li?="},
               {"tailscale-user-profile-pic", "=?utf-8?b?aHR0cHM6Ly9leGFtcGxlLmNvbQ==?="},
               {"tailscale-app-capabilities", "=?utf-8?q?{\"a\":?= =?utf-8?q?null}?="}
             ])

    assert actor.name == "René _  Li"
    assert actor.profile_pic == "https://example.com"
    assert actor.capabilities == %{"a" => nil}
    assert {:ok, actor} = build([{"tailscale-user-name", "raw_underscore"}])
    assert actor.name == "raw_underscore"
    assert {:ok, actor} = build([{"tailscale-user-name", "prefix =?utf-8?q?literal?="}])
    assert actor.name == "prefix =?utf-8?q?literal?="
    assert {:ok, actor} = build([{"tailscale-user-name", "=?utf-8?q?a?=\t=?utf-8?q?b?="}])
    assert actor.name == "ab"
  end

  test "fixtures from Go's Q encoder include Unicode and words split inside JSON" do
    fixtures = Path.join(__DIR__, "fixtures/go_q.json") |> File.read!() |> Jason.decode!()

    for %{"encoded" => encoded, "value" => value} <- fixtures do
      field =
        if String.starts_with?(value, "{"),
          do: "tailscale-app-capabilities",
          else: "tailscale-user-name"

      assert {:ok, actor} = build([{field, encoded}])

      if field == "tailscale-app-capabilities" do
        assert actor.capabilities === Jason.decode!(value)
        assert length(String.split(encoded, " ")) > 2
      else
        assert actor.name == value
      end
    end
  end

  test "encoded JSON formatting whitespace remains ordinary JSON" do
    assert {:ok, actor} =
             build([{"tailscale-app-capabilities", "=?utf-8?q?{=0A=09\"x\":_null=0D=0A}?="}])

    assert actor.capabilities == %{"x" => nil}
  end

  test "display decoding failures become nil; identity and capabilities remain strict" do
    for value <- [
          "=?utf-8?q?bad=ZZ?=",
          "=?utf-8?q?bad=?=",
          "=?utf-8?q?bad=0?=",
          "=?utf-8?q?=FF?=",
          "=?utf-8?q?=00?=",
          "=?utf-8?q?=0D=0A?=",
          "=?utf-8?q?raw space?=",
          "=?utf-8?q?ok?= trailing",
          "=?utf-8?q?ok?==?utf-8?q?ok?=",
          "=?iso-8859-1?q?=E9?=",
          "=?utf-8?x?ok?=",
          "=?utf-8?b?!!!!?=",
          "=?",
          "=?foo",
          <<255>>,
          "=?utf-8?q?unterminated",
          "raw\tvalue",
          <<127>>
        ] do
      assert {:ok, actor} =
               build([
                 {"tailscale-user-name", value},
                 {"tailscale-user-profile-pic", value},
                 {"tailscale-app-capabilities", "{\"opaque\":null}"}
               ])

      assert actor.name == nil
      assert actor.profile_pic == nil
      assert actor.login == "Alice"
      assert actor.capabilities == %{"opaque" => nil}
      assert {:error, _} = AshTailscale.from_headers([{"tailscale-user-login", value}])
      assert {:error, _} = build([{"tailscale-app-capabilities", value}])
    end
  end

  test "invalid display data still cannot bypass raw or decoded byte limits" do
    for header <- ["tailscale-user-name", "tailscale-user-profile-pic"],
        value <- [
          "=?foo" <> String.duplicate("a", 16_384),
          String.duplicate("a", 4096) <> "\t",
          "=?utf-8?q?" <> String.duplicate("a", 4096) <> "=00?="
        ] do
      assert {:error, _} = build([{header, value}])
    end
  end

  test "decoded byte limits include UTF-8 bytes and are inclusive" do
    for {header, max} <- [
          {"tailscale-user-login", 1024},
          {"tailscale-user-name", 4096},
          {"tailscale-user-profile-pic", 4096}
        ] do
      headers = [{"tailscale-user-login", "a"}] |> Enum.reject(&(elem(&1, 0) == header))

      assert {:ok, _} =
               AshTailscale.from_headers(
                 headers ++ [{header, String.duplicate("é", div(max, 2))}]
               )

      assert {:error, _} =
               AshTailscale.from_headers(headers ++ [{header, String.duplicate("a", max + 1)}])

      assert {:error, _} =
               AshTailscale.from_headers(
                 headers ++ [{header, "=?utf-8?q?" <> String.duplicate("a", max + 1) <> "?="}]
               )
    end

    json = Jason.encode!(%{"x" => String.duplicate("a", 16_384 - 8)})
    assert byte_size(json) == 16_384
    assert {:ok, _} = build([{"tailscale-app-capabilities", json}])
    assert {:error, _} = build([{"tailscale-app-capabilities", json <> " "}])
  end

  test "raw byte limits reject even when decoded content would fit" do
    # Separating whitespace disappears only between encoded words.
    for {header, max} <- [
          {"tailscale-user-login", 4096},
          {"tailscale-user-name", 16_384},
          {"tailscale-user-profile-pic", 16_384},
          {"tailscale-app-capabilities", 65_536}
        ] do
      {left, right} = if header == "tailscale-app-capabilities", do: {"{", "}"}, else: {"a", "b"}
      base = "=?utf-8?q?#{left}?=" <> "=?utf-8?q?#{right}?="

      value =
        "=?utf-8?q?#{left}?=" <>
          String.duplicate(" ", max - byte_size(base)) <> "=?utf-8?q?#{right}?="

      headers = [{"tailscale-user-login", "a"}] |> Enum.reject(&(elem(&1, 0) == header))
      assert byte_size(value) == max
      assert {:ok, _} = AshTailscale.from_headers(headers ++ [{header, value}])

      assert {:error, _} =
               AshTailscale.from_headers(
                 headers ++ [{header, String.replace(value, "?= ", "?=  ", global: false)}]
               )
    end
  end
end
