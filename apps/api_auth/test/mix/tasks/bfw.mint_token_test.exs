defmodule Mix.Tasks.Bfw.MintTokenTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Bfw.MintToken

  setup do
    Mix.shell(Mix.Shell.Process)
    :ok
  end

  test "run/1 --full prints a token with maximum privilege claims and no observe_all" do
    MintToken.run(["--full", "--exp", "1h"])

    assert_received {:mix_shell, :info, [token]}
    claims = claims_of(token)

    assert claims["lane:default"] == "write"
    assert claims["zeeky_boogie_doog"] == true
    refute Map.has_key?(claims, "observe_all")
  end

  test "run/1 --claim coerces true and false and keeps other values as strings" do
    MintToken.run([
      "--claim",
      "deploy_bpmn=true",
      "--claim",
      "observe_all=false",
      "--claim",
      "lane:Management=write"
    ])

    assert_received {:mix_shell, :info, [token]}
    claims = claims_of(token)

    assert claims["deploy_bpmn"] == true
    assert claims["observe_all"] == false
    assert claims["lane:Management"] == "write"
  end

  test "run/1 rejects a duration it cannot parse" do
    MintToken.run(["--exp", "nope"])

    assert_received {:mix_shell, :error, [message]}
    assert message =~ "nope"
  end

  defp claims_of(token) do
    secret =
      System.get_env("BFE_JWT_HS256_SECRET") ||
        Application.get_env(:api_auth, :hs256_secret) ||
        "AveOmnissiah_FromTheHolyForgesOfMars_NotAProductionSecret_Mechanicus!!"

    jwk = JOSE.JWK.from_oct(secret)
    {true, %JOSE.JWT{fields: claims}, _jws} = JOSE.JWT.verify_strict(jwk, ["HS256"], token)
    claims
  end
end
