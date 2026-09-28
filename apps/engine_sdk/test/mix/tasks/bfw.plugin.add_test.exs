defmodule Mix.Tasks.Bfw.Plugin.AddTest do
  use ExUnit.Case, async: false

  import Igniter.Test

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous_shell) end)
    :ok
  end

  test "adds the dependency, the release entry, the config line, and prints the env line" do
    igniter =
      test_project(files: host_files())
      |> Igniter.compose_task("bfw.plugin.add", ["--path", "plugins/sample_plugin"])

    assert igniter.issues == []
    assert_plugin_wired(igniter, "sample_plugin", "../plugins/sample_plugin", "SamplePlugin")
    assert_receive {:mix_shell, :info, ["BFE_PLUGINS_INBEAM=sample_plugin"]}
  end

  test "rejects --app when it differs from the plugin mix.exs" do
    igniter =
      test_project(files: host_files())
      |> Igniter.compose_task("bfw.plugin.add", [
        "--path",
        "plugins/sample_plugin",
        "--app",
        "other_plugin"
      ])

    assert Enum.any?(igniter.issues, &(&1 =~ "other_plugin"))
    assert Enum.any?(igniter.issues, &(&1 =~ "sample_plugin"))
    assert_unchanged(igniter, ["host/mix.exs", "config/config.exs"])
  end

  test "rejects a dependency that already uses a different path" do
    files =
      host_files()
      |> Map.update!("host/mix.exs", fn content ->
        String.replace(
          content,
          "{:api_web, path: \"../apps/api_web\"}",
          "{:api_web, path: \"../apps/api_web\"},\n      {:sample_plugin, path: \"../plugins/elsewhere\"}"
        )
      end)

    igniter =
      test_project(files: files)
      |> Igniter.compose_task("bfw.plugin.add", ["--path", "plugins/sample_plugin"])

    assert Enum.any?(igniter.issues, &(&1 =~ "../plugins/elsewhere"))
    assert_unchanged(igniter, ["host/mix.exs"])
  end

  test "reports an issue when the host has no release applications list" do
    files =
      Map.update!(host_files(), "host/mix.exs", fn content ->
        String.replace(content, "applications: [", "apps: [")
      end)

    igniter =
      test_project(files: files)
      |> Igniter.compose_task("bfw.plugin.add", ["--path", "plugins/sample_plugin"])

    assert Enum.any?(igniter.issues, &(&1 =~ "applications: ["))
    assert_unchanged(igniter, ["host/mix.exs"])
  end

  test "ignores a commented app: line in the plugin mix.exs" do
    files =
      Map.update!(host_files(), "plugins/sample_plugin/mix.exs", fn content ->
        "# app: :commented_out\n" <> content
      end)

    igniter =
      test_project(files: files)
      |> Igniter.compose_task("bfw.plugin.add", ["--path", "plugins/sample_plugin"])

    assert igniter.issues == []
    assert_plugin_wired(igniter, "sample_plugin", "../plugins/sample_plugin", "SamplePlugin")
  end

  test "writes the config entry before import_config" do
    files =
      Map.put(
        host_files(),
        "config/config.exs",
        "import Config\n\nconfig :logger, level: :info\n\nimport_config \"\#{config_env()}.exs\"\n"
      )

    igniter =
      test_project(files: files)
      |> Igniter.compose_task("bfw.plugin.add", ["--path", "plugins/sample_plugin"])

    config_content = source_content(igniter, "config/config.exs")
    [before_import, _after_import] = String.split(config_content, "import_config")
    assert before_import =~ "config :sample_plugin, :plugin_module, SamplePlugin"
  end

  test "a plugin named web is added beside api_web" do
    files =
      Map.put(host_files(), "plugins/web/mix.exs", """
      defmodule Web.MixProject do
        use Mix.Project

        def project do
          [app: :web, version: "0.1.0", deps: []]
        end
      end
      """)
      |> Map.put("plugins/web/lib/web/application.ex", """
      defmodule Web.Application do
        use Application

        def start(_type, _args) do
          Application.put_env(:web, :plugin_module, Web)
          Supervisor.start_link([], strategy: :one_for_one)
        end
      end
      """)

    igniter =
      test_project(files: files)
      |> Igniter.compose_task("bfw.plugin.add", ["--path", "plugins/web"])

    assert igniter.issues == []
    host_content = source_content(igniter, "host/mix.exs")
    assert host_content =~ "api_web: :permanent"
    assert Regex.scan(~r/(?<![a-z0-9_])web: :permanent/, host_content) |> length() == 1
  end

  test "a second run changes nothing" do
    first_run =
      test_project(files: host_files())
      |> Igniter.compose_task("bfw.plugin.add", ["--path", "plugins/sample_plugin"])

    seeded = file_contents(first_run, ["host/mix.exs", "config/config.exs"])

    second_run =
      test_project(files: Map.merge(host_files(), seeded))
      |> Igniter.compose_task("bfw.plugin.add", ["--path", "plugins/sample_plugin"])

    assert second_run.issues == []
    assert_unchanged(second_run, ["host/mix.exs", "config/config.exs"])
  end

  defp assert_plugin_wired(igniter, application_name, relative_path, plugin_module) do
    host_content = source_content(igniter, "host/mix.exs")
    config_content = source_content(igniter, "config/config.exs")

    assert host_content =~ "{:#{application_name}, path: \"#{relative_path}\"}"
    assert host_content |> String.split("#{application_name}: :permanent") |> length() == 2
    assert config_content =~ "# BFE_PLUGINS_INBEAM=#{application_name}"
    assert config_content =~ "config :#{application_name}, :plugin_module, #{plugin_module}"
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
      "config/config.exs" => "import Config\n",
      "plugins/sample_plugin/mix.exs" => """
      defmodule SamplePlugin.MixProject do
        use Mix.Project

        def project do
          [app: :sample_plugin, version: "0.1.0", deps: []]
        end
      end
      """,
      "plugins/sample_plugin/lib/sample_plugin/application.ex" => """
      defmodule SamplePlugin.Application do
        use Application

        def start(_type, _args) do
          Application.put_env(:sample_plugin, :plugin_module, SamplePlugin)
          Supervisor.start_link([], strategy: :one_for_one)
        end
      end
      """
    }
  end
end
