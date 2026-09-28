if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Bfw.Gen.Plugin do
    @shortdoc "Generates an in-BEAM plugin and wires it into the release host"

    @moduledoc """
    #{@shortdoc}

    Writes an OTP application under `plugins/<name>` (or `--path`) that
    compiles against `engine_sdk`, then runs `mix bfw.plugin.add`.

    The name must match `^[a-z][a-z0-9_]*$`. The plugin module is
    `Macro.camelize(name)` with no `BfwEngine` prefix. A second run, when
    `mix.exs` already exists at the path, creates no files and still runs
    `bfw.plugin.add`.

    ## Example

        mix bfw.gen.plugin sample_plugin
        mix bfw.gen.plugin sample_plugin --path plugins/sample_plugin
    """

    use Igniter.Mix.Task

    @name_pattern ~r/^[a-z][a-z0-9_]*$/

    @impl Igniter.Mix.Task
    def supports_umbrella?, do: true

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :bfw,
        example: "mix bfw.gen.plugin sample_plugin",
        positional: [:name],
        schema: [path: :string],
        defaults: [],
        composes: ["bfw.plugin.add"],
        aliases: [],
        required: []
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      plugin_name = igniter.args.positional[:name]
      plugin_path = igniter.args.options[:path] || Path.join("plugins", plugin_name)

      cond do
        not is_binary(plugin_name) or not Regex.match?(@name_pattern, plugin_name) ->
          Igniter.add_issue(
            igniter,
            "Plugin name must match #{inspect(@name_pattern)}. Nothing was written."
          )

        not inside_project?(plugin_path) ->
          Igniter.add_issue(igniter, "Plugin path #{plugin_path} is outside the Engine project.")

        true ->
          igniter
          |> maybe_write_skeleton(plugin_name, plugin_path)
          |> Igniter.compose_task("bfw.plugin.add", ["--path", plugin_path])
      end
    end

    defp maybe_write_skeleton(igniter, plugin_name, plugin_path) do
      mix_path = Path.join(plugin_path, "mix.exs")

      if Igniter.exists?(igniter, mix_path) do
        igniter
      else
        module_name = Macro.camelize(plugin_name)
        engine_sdk_path = path_to_engine_sdk(plugin_path)

        igniter
        |> Igniter.create_new_file(mix_path, mix_exs(module_name, plugin_name, engine_sdk_path))
        |> Igniter.create_new_file(
          Path.join([plugin_path, "lib", plugin_name, "application.ex"]),
          application_ex(module_name, plugin_name)
        )
        |> Igniter.create_new_file(
          Path.join([plugin_path, "lib", plugin_name, "plugin.ex"]),
          plugin_ex(module_name)
        )
        |> Igniter.create_new_file(
          Path.join([plugin_path, "lib", plugin_name, "capabilities.ex"]),
          capabilities_ex(module_name)
        )
      end
    end

    defp inside_project?(plugin_path) do
      root = File.cwd!()
      expanded = Path.expand(plugin_path, root)
      expanded == root or String.starts_with?(expanded, root <> "/")
    end

    defp path_to_engine_sdk(plugin_path) do
      root = File.cwd!()

      Path.relative_to(
        Path.expand("apps/engine_sdk", root),
        Path.expand(plugin_path, root),
        force: true
      )
    end

    defp mix_exs(module_name, plugin_name, engine_sdk_path) do
      """
      defmodule #{module_name}.MixProject do
        use Mix.Project

        def project do
          [
            app: :#{plugin_name},
            version: "0.1.0",
            elixir: "~> 1.20",
            start_permanent: Mix.env() == :prod,
            deps: deps()
          ]
        end

        def application do
          [
            extra_applications: [:logger],
            mod: {#{module_name}.Application, []}
          ]
        end

        defp deps do
          [
            {:engine_sdk, path: "#{engine_sdk_path}"}
          ]
        end
      end
      """
    end

    defp application_ex(module_name, plugin_name) do
      """
      defmodule #{module_name}.Application do
        @moduledoc false

        use Application

        @impl true
        def start(_type, _args) do
          Application.put_env(:#{plugin_name}, :plugin_module, #{module_name})

          Supervisor.start_link([], strategy: :one_for_one, name: #{module_name}.Supervisor)
        end
      end
      """
    end

    defp plugin_ex(module_name) do
      """
      defmodule #{module_name} do
        @moduledoc false

        @behaviour BfwEngine.Plugin

        @impl true
        def on_load(engine_facade), do: #{module_name}.Capabilities.register(engine_facade)

        @impl true
        def on_ready(engine_facade), do: #{module_name}.Capabilities.ready(engine_facade)
      end
      """
    end

    defp capabilities_ex(module_name) do
      """
      defmodule #{module_name}.Capabilities do
        @moduledoc false

        def register(_engine_facade), do: :ok

        def ready(_engine_facade), do: :ok
      end
      """
    end
  end
else
  defmodule Mix.Tasks.Bfw.Gen.Plugin do
    @shortdoc "Generates an in-BEAM plugin and wires it into the release host | Install `igniter` to use"

    @moduledoc @shortdoc

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      The task 'bfw.gen.plugin' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
