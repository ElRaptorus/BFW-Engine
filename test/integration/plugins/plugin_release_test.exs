defmodule BfwEngine.Integration.PluginReleaseTest do
  @moduledoc """
  `mix bfw.gen.plugin` produces an OTP app that `mix release` includes.

  `mix release` runs at the repository root, so the root alias that
  delegates to `host/mix.exs` is exercised too.

  The release is built with `MIX_ENV=prod` because `logger_json` is a
  prod-only dependency of the host project. The release is not booted.
  """

  use ExUnit.Case, async: false

  @moduletag :release
  @moduletag timeout: 900_000

  @plugin_name "plugin_release_check"
  @plugin_directory "plugins/#{@plugin_name}"

  test "generates a plugin, releases it, and the callbacks return :ok" do
    host_mix = File.read!("host/mix.exs")
    config = File.read!("config/config.exs")

    on_exit(fn ->
      File.write!("host/mix.exs", host_mix)
      File.write!("config/config.exs", config)
      File.rm_rf!(@plugin_directory)
      File.rm_rf!("_build/prod/rel/bfw_engine")
    end)

    Mix.Task.rerun("bfw.gen.plugin", [@plugin_name, "--yes"])

    assert File.exists?(Path.join(@plugin_directory, "mix.exs"))

    assert File.read!("host/mix.exs") =~
             ~s|{:#{@plugin_name}, path: "../plugins/#{@plugin_name}"}|

    assert File.read!("config/config.exs") =~
             "config :#{@plugin_name}, :plugin_module, PluginReleaseCheck"

    {output, exit_code} =
      System.cmd("mix", ["release", "--overwrite"],
        env: [{"MIX_ENV", "prod"}],
        stderr_to_stdout: true
      )

    assert exit_code == 0, output

    release_library = Path.join(["_build", "prod", "rel", "bfw_engine", "lib"])

    assert Enum.any?(File.ls!(release_library), &String.starts_with?(&1, "#{@plugin_name}-"))

    start_script =
      File.read!(
        Path.join(["_build", "prod", "rel", "bfw_engine", "releases", "0.1.0", "start.script"])
      )

    assert start_script =~ @plugin_name

    Code.compile_file(Path.join([@plugin_directory, "lib", @plugin_name, "capabilities.ex"]))
    Code.compile_file(Path.join([@plugin_directory, "lib", @plugin_name, "plugin.ex"]))

    plugin_module = Module.concat([Macro.camelize(@plugin_name)])
    assert :ok = plugin_module.on_load(%{})
    assert :ok = plugin_module.on_ready(%{})
  end
end
