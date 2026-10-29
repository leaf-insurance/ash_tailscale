defmodule AshTailscaleTest do
  use ExUnit.Case, async: true
  alias AshAuthentication.Strategy

  test "library-owned transient resource and route-less, token-free sign-in" do
    assert Ash.Resource.Info.domain(AshTailscale.User) == AshTailscale.Domain
    assert Ash.Resource.Info.data_layer(AshTailscale.User) == Ash.DataLayer.Simple
    assert Ash.Resource.Info.primary_key(AshTailscale.User) == [:login]
    refute AshAuthentication.Info.authentication_tokens_enabled?(AshTailscale.User)
    strategy = AshAuthentication.Info.strategy!(AshTailscale.User, :tailscale)
    assert Strategy.actions(strategy) == [:sign_in]
    assert Strategy.phases(strategy) == []
    assert Strategy.routes(strategy) == []
    refute Strategy.tokens_required?(strategy)

    headers = [{"tailscale-user-login", "alice@example.com"}]
    assertion = %AshTailscale.Assertion{headers: headers}
    assert {:ok, actor} = Strategy.action(strategy, :sign_in, %{assertion: assertion}, [])
    assert {:ok, ^actor} = AshTailscale.from_headers(headers)
    assert AshTailscale.actor?(actor)
    assert actor.login == "alice@example.com"
    refute Map.has_key?(actor.__metadata__, :token)

    for params <- [%{"login" => "alice"}, %{login: "alice"}, %{assertion: %{headers: headers}}] do
      assert {:error, _} = Strategy.action(strategy, :sign_in, params, [])
    end
  end

  test "a subject cannot restore identity or capabilities, even with authorization disabled" do
    actor = AshTailscale.test_actor!("alice", %{"permission" => true})
    subject = AshAuthentication.user_to_subject(actor)

    assert {:error, _} = AshAuthentication.subject_to_user(subject, AshTailscale.User)

    assert {:error, _} =
             AshAuthentication.subject_to_user(subject, AshTailscale.User, authorize?: false)

    assert {:error, _} =
             AshTailscale.User
             |> Ash.Query.for_read(:get_by_subject, %{subject: subject})
             |> Ash.DataLayer.Simple.set_data([actor])
             |> Ash.read(authorize?: false)
  end
end
