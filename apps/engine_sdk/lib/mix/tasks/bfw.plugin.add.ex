if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Bfw.Plugin.Add do
    @shortdoc "Wires an in-BEAM plugin into the Engine release host"

    @moduledoc """
    #{@shortdoc}

    Adds the plugin OTP application as a path dependency of `host/mix.exs`,
    appends it to the `:bfw_engine` release applications list, and sets
    `config :<app>, :plugin_module, <Module>` in `config/config.exs`.

    The module is read from the plugin's `application.ex`
    (`Application.put_env` argument). The task prints
    `BFE_PLUGINS_INBEAM=<app>` and writes that line once as a comment
    above the new config entry. It does not set the environment variable.

    ## Example

        mix bfw.plugin.add --path plugins/sample_plugin

    A second run with the same application, path, release entry, and
    plugin module changes nothing. If the application is already a
    dependency with a different path, the task fails.
    """

    use Igniter.Mix.Task

    @host_mix "host/mix.exs"
    @config_file "config/config.exs"
    @plugin_name_pattern ~r/^[a-z][a-z0-9_]*$/

    @impl Igniter.Mix.Task
    def supports_umbrella?, do: true

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :bfw,
        example: "mix bfw.plugin.add --path plugins/sample_plugin",
        positional: [],
        schema: [path: :string, app: :string],
        defaults: [],
        composes: [],
        aliases: [],
        required: [:path]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      options = igniter.args.options
      plugin_path = options[:path]

      case ensure_inside_project(plugin_path) do
        :ok ->
          case wire_plugin(igniter, plugin_path, options[:app]) do
            {:ok, igniter, application_name} ->
              Mix.shell().info("BFE_PLUGINS_INBEAM=#{application_name}")
              igniter

            {:error, igniter, message} ->
              Igniter.add_issue(igniter, message)
          end

        {:error, message} ->
          Igniter.add_issue(igniter, message)
      end
    end

    defp wire_plugin(igniter, plugin_path, requested_application_name) do
      with {:ok, igniter, application_name} <- read_application_name(igniter, plugin_path),
           :ok <- ensure_requested_application_name(requested_application_name, application_name),
           {:ok, igniter, plugin_module} <-
             read_plugin_module(igniter, plugin_path, application_name),
           {:ok, igniter} <- wire_host(igniter, application_name, plugin_path),
           {:ok, igniter} <- wire_config(igniter, application_name, plugin_module) do
        {:ok, igniter, application_name}
      else
        {:error, message} ->
          {:error, igniter, message}

        {:error, igniter, message} ->
          {:error, igniter, message}
      end
    end

    defp ensure_inside_project(plugin_path) do
      root = File.cwd!()
      expanded = Path.expand(plugin_path, root)

      if expanded == root or String.starts_with?(expanded, root <> "/") do
        :ok
      else
        {:error, "Plugin path #{plugin_path} is outside the Engine project."}
      end
    end

    defp ensure_requested_application_name(nil, _declared_application_name), do: :ok

    defp ensure_requested_application_name(requested, declared) do
      if requested == declared do
        :ok
      else
        {:error, "--app #{requested} does not match the mix.exs application name #{declared}."}
      end
    end

    defp read_application_name(igniter, plugin_path) do
      mix_path = Path.join(plugin_path, "mix.exs")
      {igniter, content} = file_content(igniter, mix_path)

      case content && Regex.run(~r/(?:^|[\[,])\s*app:\s*:([a-z][a-z0-9_]*)/m, content) do
        [_, application_name] ->
          if Regex.match?(@plugin_name_pattern, application_name) do
            {:ok, igniter, application_name}
          else
            {:error, igniter,
             "Plugin application name #{application_name} is not a valid OTP application name."}
          end

        _ ->
          {:error, igniter, "Could not read app: from #{mix_path}."}
      end
    end

    defp read_plugin_module(igniter, plugin_path, application_name) do
      application_path = Path.join([plugin_path, "lib", application_name, "application.ex"])
      {igniter, content} = file_content(igniter, application_path)

      case content &&
             Regex.run(
               ~r/Application\.put_env\(\s*:[a-z][a-z0-9_]*\s*,\s*:plugin_module\s*,\s*([A-Z][A-Za-z0-9_\.]*)\s*\)/,
               content
             ) do
        [_, plugin_module] ->
          {:ok, igniter, plugin_module}

        _ ->
          {:error, igniter,
           "Could not read the :plugin_module from #{application_path}. The Application.start/2 callback must call Application.put_env."}
      end
    end

    defp wire_host(igniter, application_name, plugin_path) do
      if Igniter.exists?(igniter, @host_mix) do
        {igniter, content} = file_content(igniter, @host_mix)
        relative_path = path_from_host(plugin_path)

        case add_dependency_and_release(content, application_name, relative_path) do
          {:ok, updated} when updated == content ->
            {:ok, igniter}

          {:ok, updated} ->
            {:ok,
             Igniter.update_file(igniter, @host_mix, fn source ->
               Rewrite.Source.update(source, :content, updated)
             end)}

          {:error, message} ->
            {:error, igniter, message}
        end
      else
        {:error, igniter,
         "Could not find #{@host_mix}. Run this task from the Engine repository root."}
      end
    end

    defp wire_config(igniter, application_name, plugin_module) do
      igniter = Igniter.include_or_create_file(igniter, @config_file, "import Config\n")
      {igniter, content} = file_content(igniter, @config_file)
      updated = ensure_plugin_module_config(content, application_name, plugin_module)

      igniter =
        if updated == content do
          igniter
        else
          Igniter.update_file(igniter, @config_file, fn source ->
            Rewrite.Source.update(source, :content, updated)
          end)
        end

      {:ok, igniter}
    end

    defp add_dependency_and_release(content, application_name, relative_path) do
      with {:ok, content} <- ensure_path_dependency(content, application_name, relative_path) do
        ensure_release_application(content, application_name)
      end
    end

    defp ensure_path_dependency(content, application_name, relative_path) do
      case Regex.run(~r/\{:#{application_name},\s*path:\s*"([^"]+)"\}/, content) do
        [_, ^relative_path] ->
          {:ok, content}

        [_, existing_path] ->
          {:error,
           "Dependency :#{application_name} is already declared with path #{existing_path}, not #{relative_path}."}

        nil ->
          entry = "{:#{application_name}, path: \"#{relative_path}\"}"

          replace_single_match(
            content,
            ~r/(defp deps do\s*\[[\s\S]*?)(\n\s*\])/,
            fn _whole, body, closing ->
              String.trim_trailing(body) <> ",\n      #{entry}" <> closing
            end,
            "a single `defp deps do [` list"
          )
      end
    end

    defp ensure_release_application(content, application_name) do
      needle = "#{application_name}: :permanent"
      already_present? = Regex.match?(~r/(?<![a-z0-9_])#{Regex.escape(needle)}/, content)

      if already_present? do
        {:ok, content}
      else
        replace_single_match(
          content,
          ~r/(?<![A-Za-z_])(applications:\s*\[[\s\S]*?)(\n\s*\])/,
          fn _whole, body, closing ->
            String.trim_trailing(body) <> ",\n          #{needle}" <> closing
          end,
          "a single release `applications: [` list"
        )
      end
    end

    defp replace_single_match(content, pattern, replacement, description) do
      case length(Regex.scan(pattern, content)) do
        1 -> {:ok, Regex.replace(pattern, content, replacement)}
        _count -> {:error, "Could not find #{description} in #{@host_mix}."}
      end
    end

    defp ensure_plugin_module_config(content, application_name, plugin_module) do
      config_line = "config :#{application_name}, :plugin_module, #{plugin_module}"

      if String.contains?(content, config_line) do
        content
      else
        entry = "# BFE_PLUGINS_INBEAM=#{application_name}\n#{config_line}\n"
        import_pattern = ~r/^import_config .*$/m

        if Regex.match?(import_pattern, content) do
          [before_import | rest] =
            Regex.split(import_pattern, content, parts: 2, include_captures: true)

          String.trim_trailing(before_import) <> "\n\n#{entry}\n" <> Enum.join(rest)
        else
          String.trim_trailing(content) <> "\n#{entry}"
        end
      end
    end

    defp path_from_host(plugin_path) do
      root = File.cwd!()

      Path.relative_to(
        Path.expand(plugin_path, root),
        Path.expand("host", root),
        force: true
      )
    end

    defp file_content(igniter, path) do
      igniter =
        if Igniter.exists?(igniter, path) do
          Igniter.include_existing_file(igniter, path)
        else
          igniter
        end

      if Rewrite.has_source?(igniter.rewrite, path) do
        {igniter, Rewrite.Source.get(Rewrite.source!(igniter.rewrite, path), :content)}
      else
        {igniter, nil}
      end
    end
  end
else
  defmodule Mix.Tasks.Bfw.Plugin.Add do
    @shortdoc "Wires an in-BEAM plugin into the Engine release host | Install `igniter` to use"

    @moduledoc @shortdoc

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      The task 'bfw.plugin.add' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
