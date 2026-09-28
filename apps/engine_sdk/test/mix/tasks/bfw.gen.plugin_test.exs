defmodule Mix.Tasks.Bfw.Gen.PluginTest do
  use ExUnit.Case, async: false

  import Igniter.Test

  test "writes the skeleton at the default path and wires the host" do
    igniter =
      test_project(files: host_files())
      |> Igniter.compose_task("bfw.gen.plugin", ["sample_plugin"])

    assert igniter.issues == []

    assert_creates(igniter, "plugins/sample_plugin/mix.exs", fn content ->
      assert content =~ "app: :sample_plugin"
      assert content =~ ~s|{:engine_sdk, path: "../../apps/engine_sdk"}|
    end)

    assert_creates(igniter, "plugins/sample_plugin/lib/sample_plugin/plugin.ex", fn content ->
      assert content =~ "defmodule SamplePlugin do"
      assert content =~ "SamplePlugin.Capabilities.register"
      assert content =~ "SamplePlugin.Capabilities.ready"
    end)

    assert_creates(
      igniter,
      "plugins/sample_plugin/lib/sample_plugin/application.ex",
      fn content ->
        assert content =~ "Application.put_env(:sample_plugin, :plugin_module, SamplePlugin)"
      end
    )

    assert_creates(
      igniter,
      "plugins/sample_plugin/lib/sample_plugin/capabilities.ex",
      fn content ->
        assert content =~ "def register(_engine_facade), do: :ok"
        assert content =~ "def ready(_engine_facade), do: :ok"
      end
    )

    host_content = source_content(igniter, "host/mix.exs")
    assert host_content =~ ~s|{:sample_plugin, path: "../plugins/sample_plugin"}|
    assert host_content |> String.split("sample_plugin: :permanent") |> length() == 2
  end

  test "honours a custom path" do
    igniter =
      test_project(files: host_files())
      |> Igniter.compose_task("bfw.gen.plugin", [
        "sample_plugin",
        "--path",
        "plugins/custom_sample"
      ])

    assert igniter.issues == []

    assert_creates(igniter, "plugins/custom_sample/lib/sample_plugin/plugin.ex", fn content ->
      assert content =~ "defmodule SamplePlugin do"
    end)

    host_content = source_content(igniter, "host/mix.exs")
    assert host_content =~ ~s|{:sample_plugin, path: "../plugins/custom_sample"}|
  end

  test "an invalid name writes nothing" do
    igniter =
      test_project(files: host_files())
      |> Igniter.compose_task("bfw.gen.plugin", ["Bad-Name"])

    assert igniter.issues != []
    refute Rewrite.has_source?(igniter.rewrite, "plugins/Bad-Name/mix.exs")
    assert_unchanged(igniter, ["host/mix.exs", "config/config.exs"])
  end

  test "a second run creates nothing new and keeps the add edits" do
    first_run =
      test_project(files: host_files())
      |> Igniter.compose_task("bfw.gen.plugin", ["sample_plugin"])

    paths = [
      "plugins/sample_plugin/mix.exs",
      "plugins/sample_plugin/lib/sample_plugin/application.ex",
      "plugins/sample_plugin/lib/sample_plugin/plugin.ex",
      "plugins/sample_plugin/lib/sample_plugin/capabilities.ex",
      "host/mix.exs",
      "config/config.exs"
    ]

    seeded = Map.merge(host_files(), file_contents(first_run, paths))

    second_run =
      test_project(files: seeded)
      |> Igniter.compose_task("bfw.gen.plugin", ["sample_plugin"])

    assert second_run.issues == []
    assert_unchanged(second_run, paths)
  end

  defp file_contents(igniter, paths) do
    Map.new(paths, fn path -> {path, source_content(igniter, path)} end)
  end

  defp source_content(igniter, path) do
    igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)
  end

  defp host_files do
    %{
      "host/mix.exs" => """
      defmodule HostFixture.MixProject do
        use Mix.Project

        def project do
          [app: :bfw_engine, deps: deps(), releases: releases()]
        end

        def application do
          [extra_applications: [:logger]]
        end

        defp deps do
          [
            {:api_web, path: "../apps/api_web"}
          ]
        end

        defp releases do
          [
            bfw_engine: [
              applications: [
                api_web: :permanent
              ]
            ]
          ]
        end
      end
      """,
      "config/config.exs" => "import Config\n"
    }
  end
end
