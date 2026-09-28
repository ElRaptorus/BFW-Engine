if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.BfwEngineClient.Install do
    @shortdoc "Wires BfwEngine.Client into a host application"

    @moduledoc """
    #{@shortdoc}

    Adds Engine base URL configuration to `config/runtime.exs`, generates a
    thin `<App>.Engine` module exposing `client/0` (service token) and
    `client/1` (per-user token), and starts a
    `BfwEngine.Client.Notifications` process in the application's
    supervision tree.

    ## Example

    ```sh
    mix igniter.install bfw_engine_client@path:../packages/elixir/bfw_engine_client
    ```

    ## Options

      * `--base-url-env` - environment variable read for the Engine's base
        URL. Defaults to `BFE_ENGINE_URL`.
      * `--token-env` - environment variable read for the service token.
        Defaults to `BFE_ENGINE_TOKEN`.

    Re-running this task changes nothing once the configuration, module,
    and supervision-tree entry already exist.
    """

    use Igniter.Mix.Task

    alias Igniter.Project.Application, as: IgniterApplication
    alias Igniter.Project.Config, as: IgniterConfig
    alias Igniter.Project.Module, as: IgniterModule

    @default_base_url_env "BFE_ENGINE_URL"
    @default_token_env "BFE_ENGINE_TOKEN"
    @default_base_url "http://localhost:4100"

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :bfw_engine_client,
        example: "mix bfw_engine_client.install",
        positional: [],
        schema: [base_url_env: :string, token_env: :string],
        defaults: [base_url_env: @default_base_url_env, token_env: @default_token_env],
        composes: [],
        aliases: [],
        required: []
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      options = igniter.args.options
      base_url_env = options[:base_url_env]
      token_env = options[:token_env]

      app_name = IgniterApplication.app_name(igniter)
      engine_module = IgniterModule.module_name(igniter, "Engine")
      notifications_module = Module.concat(engine_module, "Notifications")

      igniter
      |> configure_base_url(app_name, engine_module, base_url_env)
      |> create_engine_module(app_name, engine_module, token_env)
      |> start_notifications(engine_module, notifications_module)
    end

    defp configure_base_url(igniter, app_name, engine_module, base_url_env) do
      base_url_expression =
        Sourceror.parse_string!(
          ~s|System.get_env(#{inspect(base_url_env)}, #{inspect(@default_base_url)})|
        )

      IgniterConfig.configure_new(
        igniter,
        "runtime.exs",
        app_name,
        [engine_module, :base_url],
        {:code, base_url_expression}
      )
    end

    defp create_engine_module(igniter, app_name, engine_module, token_env) do
      contents = """
      @moduledoc \"\"\"
      Builds `BfwEngine.Client` structs for this application: a shared
      client authenticated with the service token (from `#{token_env}`),
      and per-user clients authenticated with an explicit token.
      \"\"\"

      alias BfwEngine.Client

      @doc "Builds a client authenticated with this application's service token."
      @spec client() :: Client.t()
      def client do
        client(System.get_env(#{inspect(token_env)}))
      end

      @doc "Builds a client authenticated with an explicit per-user token."
      @spec client(String.t() | nil) :: Client.t()
      def client(token) do
        base_url = Application.fetch_env!(#{inspect(app_name)}, __MODULE__)[:base_url]
        Client.new(base_url: base_url, token: token)
      end
      """

      IgniterModule.find_and_update_or_create_module(
        igniter,
        engine_module,
        contents,
        fn zipper -> {:ok, zipper} end
      )
    end

    defp start_notifications(igniter, engine_module, notifications_module) do
      IgniterApplication.add_new_child(
        igniter,
        {BfwEngine.Client.Notifications,
         [name: notifications_module, client: {engine_module, :client, []}]}
      )
    end
  end
else
  defmodule Mix.Tasks.BfwEngineClient.Install do
    @shortdoc "Wires BfwEngine.Client into a host application | Install `igniter` to use"

    @moduledoc @shortdoc

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      The task 'bfw_engine_client.install' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
