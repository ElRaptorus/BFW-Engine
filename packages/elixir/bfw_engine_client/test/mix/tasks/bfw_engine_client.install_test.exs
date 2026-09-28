defmodule Mix.Tasks.BfwEngineClient.InstallTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  test "creates the runtime config, the Engine module, and the supervision-tree entry" do
    igniter =
      test_project()
      |> Igniter.compose_task("bfw_engine_client.install", [])

    assert_creates(igniter, "lib/test/engine.ex", fn content ->
      assert content =~ "def client do"
      assert content =~ ~s|System.get_env("BFE_ENGINE_TOKEN")|
    end)

    assert_creates(igniter, "config/runtime.exs", fn content ->
      assert content =~
               ~s|config :test, Test.Engine, base_url: System.get_env("BFE_ENGINE_URL", "http://localhost:4100")|
    end)

    assert_creates(igniter, "lib/test/application.ex", fn content ->
      assert content =~ "BfwEngine.Client.Notifications"
    end)
  end

  test "honours custom base-url and token environment variable names" do
    igniter =
      test_project()
      |> Igniter.compose_task("bfw_engine_client.install", [
        "--base-url-env",
        "MYAPP_ENGINE_URL",
        "--token-env",
        "MYAPP_ENGINE_TOKEN"
      ])

    assert_creates(igniter, "lib/test/engine.ex", fn content ->
      assert content =~ ~s|System.get_env("MYAPP_ENGINE_TOKEN")|
    end)

    assert_creates(igniter, "config/runtime.exs", fn content ->
      assert content =~ ~s|System.get_env("MYAPP_ENGINE_URL"|
    end)
  end

  test "a second run changes nothing" do
    first_run =
      test_project()
      |> Igniter.compose_task("bfw_engine_client.install", [])

    seeded_files =
      for path <- [
            "lib/test/engine.ex",
            "config/runtime.exs",
            "lib/test/application.ex",
            "mix.exs"
          ],
          into: %{} do
        content = first_run.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)
        {path, content}
      end

    second_run =
      test_project(files: seeded_files)
      |> Igniter.compose_task("bfw_engine_client.install", [])

    assert second_run.issues == []
    assert_unchanged(second_run, Map.keys(seeded_files))
  end
end
