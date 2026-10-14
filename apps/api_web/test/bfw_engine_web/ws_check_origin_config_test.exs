defmodule BfwEngineWeb.WsCheckOriginConfigTest do
  use ExUnit.Case, async: false

  @runtime_path Path.expand("../../../../config/runtime.exs", __DIR__)

  @required_environment %{
    "BFE_DATABASE_URL" => "ecto://user:password@localhost/database",
    "BFE_HTTP_SECRET_KEY_BASE" => String.duplicate("k", 64),
    "BFE_JWT_HS256_SECRET" => String.duplicate("s", 32)
  }

  defp check_origin_for(value) do
    environment =
      case value do
        nil -> @required_environment
        value -> Map.put(@required_environment, "BFE_WS_CHECK_ORIGIN", value)
      end

    previous =
      Map.new(Map.keys(environment) ++ ["BFE_WS_CHECK_ORIGIN"], &{&1, System.get_env(&1)})

    Enum.each(environment, fn {name, setting} -> System.put_env(name, setting) end)
    if is_nil(value), do: System.delete_env("BFE_WS_CHECK_ORIGIN")

    previous_conflict_option = Code.compiler_options()[:ignore_module_conflict]
    Code.compiler_options(ignore_module_conflict: true)

    try do
      @runtime_path
      |> Config.Reader.read!(env: :prod, target: :host)
      |> get_in([:api_web, BfwEngineWeb.Http.Endpoint, :check_origin])
    after
      Code.compiler_options(ignore_module_conflict: previous_conflict_option)

      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, setting} -> System.put_env(name, setting)
      end)
    end
  end

  describe "BFE_WS_CHECK_ORIGIN in production" do
    test "defaults to disabled" do
      assert check_origin_for(nil) == false
    end

    test "true maps to Phoenix :conn so the Origin must match the request host" do
      assert check_origin_for("true") == :conn
    end

    test "false disables the check" do
      assert check_origin_for("false") == false
    end

    test "a comma-separated list is passed through as explicit origins" do
      assert check_origin_for("http://localhost:5173,https://studio.example.com") ==
               ["http://localhost:5173", "https://studio.example.com"]
    end
  end
end
