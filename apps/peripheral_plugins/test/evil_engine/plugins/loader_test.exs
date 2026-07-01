defmodule EvilEngine.Plugins.LoaderTest do
  use ExUnit.Case, async: false

  alias EvilEngine.EngineFacade
  alias EvilEngine.Plugins.Builtin.HttpServiceTaskHandler
  alias EvilEngine.Plugins.Loader
  alias EvilEngine.Plugins.Registry

  # -- Mock plugin modules ---------------------------------------------------

  defmodule GoodPlugin do
    @behaviour EvilEngine.Plugin
    def on_load(_facade), do: :ok
    def on_ready(_facade), do: :ok
  end

  defmodule FailingLoadPlugin do
    @behaviour EvilEngine.Plugin
    def on_load(_facade), do: {:error, :intentional_load_failure}
    def on_ready(_facade), do: :ok
  end

  defmodule CrashingLoadPlugin do
    @behaviour EvilEngine.Plugin
    def on_load(_facade), do: raise("boom in on_load")
    def on_ready(_facade), do: :ok
  end

  defmodule FailingReadyPlugin do
    @behaviour EvilEngine.Plugin
    def on_load(_facade), do: :ok
    def on_ready(_facade), do: {:error, :intentional_ready_failure}
  end

  defmodule CrashingReadyPlugin do
    @behaviour EvilEngine.Plugin
    def on_load(_facade), do: :ok
    def on_ready(_facade), do: raise("boom in on_ready")
  end

  defmodule NoBehaviourModule do
  end

  defmodule StubServiceTaskHandler do
    @behaviour EvilEngine.Plugin.ServiceTaskHandler
    def handle_enter(_flow_node, _token, _context), do: {:async, "stub-fni"}
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:peripheral_plugins)

    Registry.reset_state()
    Loader.register_builtin_capabilities()

    :ok
  end

  test "loader process is running under the plugins application" do
    assert is_pid(Process.whereis(Loader))
  end

  test "starts with no user plugins when inbeam_apps is empty" do
    assert [] == Loader.loaded_plugins()
  end

  test "registers built-in http service task handler on startup" do
    handlers = Registry.list_capabilities(:service_task_handler)

    assert Enum.any?(handlers, fn capability ->
             capability.descriptor[:implementation] == "http" &&
               capability.descriptor[:module] == HttpServiceTaskHandler &&
               capability.plugin_name == "evil:builtin"
           end)
  end

  test "facade_for_plugin/1 builds EngineFacade with required fields and wiring" do
    plugin_name = "facade-probe-#{System.unique_integer([:positive])}"
    facade = Loader.facade_for_plugin(plugin_name)

    assert %EngineFacade{} = facade
    assert is_binary(facade.engine_id)
    assert is_binary(facade.engine_name)
    assert is_binary(facade.version)
    assert is_function(facade.register_service_task_handler, 2)
    assert is_function(facade.register_named_script, 2)
    assert is_function(facade.register_persistence_adapter, 2)
    assert is_function(facade.register_rest_api_extension, 2)
    assert is_function(facade.register_monitoring_panel, 1)
    assert is_function(facade.register_timer_source, 2)
    assert is_function(facade.register_data_store_adapter, 2)
    assert is_function(facade.register_auth_provider, 1)
    assert is_function(facade.publish_event, 1)
    assert is_function(facade.register_event_sink, 3)
    assert is_function(facade.get_config, 1)
    assert %EngineFacade.Processes{} = facade.processes
    assert is_function(facade.processes.get, 1)
    assert is_function(facade.processes.deploy, 1)
    assert is_function(facade.processes.start, 1)

    assert %EngineFacade.ProcessInstances{} = facade.process_instances
    assert is_function(facade.process_instances.get, 1)
    assert is_function(facade.process_instances.abort, 2)

    assert %EngineFacade.UserTasks{} = facade.user_tasks
    assert is_function(facade.user_tasks.finish, 3)
    assert is_function(facade.user_tasks.cancel, 3)

    assert %EngineFacade.ServiceTasks{} = facade.service_tasks
    assert is_function(facade.service_tasks.finish_async, 2)
    assert is_function(facade.service_tasks.fail_async, 3)

    assert %EngineFacade.FlowNodeInstances{} = facade.flow_node_instances
    assert is_function(facade.flow_node_instances.get, 1)

    assert %EngineFacade.DataObjects{} = facade.data_objects
    assert is_function(facade.data_objects.get, 1)

    assert %EngineFacade.Decisions{} = facade.decisions
    assert is_function(facade.decisions.list, 0)
    assert is_function(facade.decisions.get, 1)
    assert is_function(facade.decisions.get_latest_version, 1)
    assert is_function(facade.decisions.deploy, 1)
    assert is_function(facade.decisions.evaluate, 3)
    assert is_function(facade.decisions.evaluate_service, 4)
    assert is_function(facade.decisions.get_versions, 1)
    assert is_function(facade.decisions.get_xml, 1)
    assert is_function(facade.decisions.enable, 1)
    assert is_function(facade.decisions.disable, 1)
    assert is_function(facade.decisions.delete_version, 2)
    assert is_function(facade.decisions.undeploy, 1)

    assert %EngineFacade.Graphql{} = facade.graphql
    assert is_function(facade.graphql.query, 2)

    handler_key = "facade-register-#{System.unique_integer([:positive])}"

    assert :ok = facade.register_service_task_handler.(handler_key, StubServiceTaskHandler)

    registered =
      Registry.list_capabilities(:service_task_handler)
      |> Enum.find(
        &((&1.descriptor[:implementation] || &1.descriptor["implementation"]) == handler_key)
      )

    assert registered.plugin_name == plugin_name
  end

  # -- Plugin lifecycle tests (via init/1 + handle_continue/2) ----------------

  describe "include/exclude filtering" do
    setup :save_and_restore_plugin_env

    test "L-1: excluded plugin is skipped" do
      Application.put_env(:peripheral_plugins, :inbeam_apps, [:test_excluded_plugin])
      Application.put_env(:peripheral_plugins, :exclude_plugins, ["test_excluded_plugin"])
      Application.put_env(:peripheral_plugins, :include_plugins, [])

      {:ok, state, _} = Loader.init([])
      {:noreply, state} = Loader.handle_continue(:on_ready, state)

      assert state.loaded_plugins == []
      assert state.quarantined_plugins == []
    end

    test "L-2: plugin in both include and exclude is quarantined" do
      Application.put_env(:peripheral_plugins, :inbeam_apps, [:test_ambig_plugin])
      Application.put_env(:peripheral_plugins, :include_plugins, ["test_ambig_plugin"])
      Application.put_env(:peripheral_plugins, :exclude_plugins, ["test_ambig_plugin"])

      {:ok, state, _} = Loader.init([])

      assert length(state.quarantined_plugins) == 1
      assert hd(state.quarantined_plugins).reason == :ambiguous_policy
    end

    test "L-3: plugin not in non-empty include list is skipped" do
      Application.put_env(:peripheral_plugins, :inbeam_apps, [:test_unlisted_plugin])
      Application.put_env(:peripheral_plugins, :include_plugins, ["other_plugin"])
      Application.put_env(:peripheral_plugins, :exclude_plugins, [])

      {:ok, state, _} = Loader.init([])

      assert state.loaded_plugins == []
      assert state.quarantined_plugins == []
    end
  end

  describe "discovery failures" do
    setup :save_and_restore_plugin_env

    test "L-4: app not loaded is quarantined" do
      Application.put_env(:peripheral_plugins, :inbeam_apps, [:nonexistent_app_xyz_42])
      Application.put_env(:peripheral_plugins, :include_plugins, [])
      Application.put_env(:peripheral_plugins, :exclude_plugins, [])

      {:ok, state, _} = Loader.init([])

      assert length(state.quarantined_plugins) == 1
      assert hd(state.quarantined_plugins).reason == :app_not_loaded
    end

    test "L-5: app without plugin_module env is quarantined" do
      Application.put_env(:peripheral_plugins, :inbeam_apps, [:peripheral_telemetry])
      Application.put_env(:peripheral_plugins, :include_plugins, [])
      Application.put_env(:peripheral_plugins, :exclude_plugins, [])

      previous_pm = Application.get_env(:peripheral_telemetry, :plugin_module)
      Application.delete_env(:peripheral_telemetry, :plugin_module)

      on_exit(fn ->
        if previous_pm,
          do: Application.put_env(:peripheral_telemetry, :plugin_module, previous_pm)
      end)

      {:ok, state, _} = Loader.init([])

      assert length(state.quarantined_plugins) == 1
      assert hd(state.quarantined_plugins).reason == :missing_plugin_module
    end

    test "L-6: module without Plugin behaviour is quarantined" do
      Application.put_env(:peripheral_plugins, :inbeam_apps, [:peripheral_telemetry])
      Application.put_env(:peripheral_plugins, :include_plugins, [])
      Application.put_env(:peripheral_plugins, :exclude_plugins, [])
      Application.put_env(:peripheral_telemetry, :plugin_module, NoBehaviourModule)

      on_exit(fn ->
        Application.delete_env(:peripheral_telemetry, :plugin_module)
      end)

      {:ok, state, _} = Loader.init([])

      assert length(state.quarantined_plugins) == 1
      assert hd(state.quarantined_plugins).reason == :invalid_plugin_module
    end
  end

  describe "on_load lifecycle" do
    setup :save_and_restore_plugin_env

    test "L-7: on_load returning error quarantines plugin" do
      Application.put_env(:peripheral_plugins, :inbeam_apps, [:peripheral_telemetry])
      Application.put_env(:peripheral_plugins, :include_plugins, [])
      Application.put_env(:peripheral_plugins, :exclude_plugins, [])
      Application.put_env(:peripheral_telemetry, :plugin_module, FailingLoadPlugin)

      on_exit(fn -> Application.delete_env(:peripheral_telemetry, :plugin_module) end)

      {:ok, state, _} = Loader.init([])

      assert length(state.quarantined_plugins) == 1
      assert hd(state.quarantined_plugins).reason == {:on_load_failed, :intentional_load_failure}
    end

    test "L-8: on_load raising exception quarantines plugin" do
      Application.put_env(:peripheral_plugins, :inbeam_apps, [:peripheral_telemetry])
      Application.put_env(:peripheral_plugins, :include_plugins, [])
      Application.put_env(:peripheral_plugins, :exclude_plugins, [])
      Application.put_env(:peripheral_telemetry, :plugin_module, CrashingLoadPlugin)

      on_exit(fn -> Application.delete_env(:peripheral_telemetry, :plugin_module) end)

      {:ok, state, _} = Loader.init([])

      assert length(state.quarantined_plugins) == 1
      assert match?({:on_load_crashed, _}, hd(state.quarantined_plugins).reason)
    end

    test "L-9: successful on_load registers plugin" do
      Application.put_env(:peripheral_plugins, :inbeam_apps, [:peripheral_telemetry])
      Application.put_env(:peripheral_plugins, :include_plugins, [])
      Application.put_env(:peripheral_plugins, :exclude_plugins, [])
      Application.put_env(:peripheral_telemetry, :plugin_module, GoodPlugin)

      on_exit(fn -> Application.delete_env(:peripheral_telemetry, :plugin_module) end)

      {:ok, state, _} = Loader.init([])

      assert length(state.loaded_plugins) == 1
      assert hd(state.loaded_plugins).name == "peripheral_telemetry"
      assert hd(state.loaded_plugins).module == GoodPlugin
    end
  end

  describe "on_ready lifecycle" do
    setup :save_and_restore_plugin_env

    test "L-10: on_ready returning error quarantines previously loaded plugin" do
      Application.put_env(:peripheral_plugins, :inbeam_apps, [:peripheral_telemetry])
      Application.put_env(:peripheral_plugins, :include_plugins, [])
      Application.put_env(:peripheral_plugins, :exclude_plugins, [])
      Application.put_env(:peripheral_telemetry, :plugin_module, FailingReadyPlugin)

      on_exit(fn -> Application.delete_env(:peripheral_telemetry, :plugin_module) end)

      {:ok, state, _} = Loader.init([])
      assert length(state.loaded_plugins) == 1

      {:noreply, final_state} = Loader.handle_continue(:on_ready, state)

      assert final_state.loaded_plugins == []
      assert length(final_state.quarantined_plugins) == 1
      assert match?({:on_ready_failed, _}, hd(final_state.quarantined_plugins).reason)
    end

    test "L-11: on_ready raising exception quarantines plugin" do
      Application.put_env(:peripheral_plugins, :inbeam_apps, [:peripheral_telemetry])
      Application.put_env(:peripheral_plugins, :include_plugins, [])
      Application.put_env(:peripheral_plugins, :exclude_plugins, [])
      Application.put_env(:peripheral_telemetry, :plugin_module, CrashingReadyPlugin)

      on_exit(fn -> Application.delete_env(:peripheral_telemetry, :plugin_module) end)

      {:ok, state, _} = Loader.init([])
      assert length(state.loaded_plugins) == 1

      {:noreply, final_state} = Loader.handle_continue(:on_ready, state)

      assert final_state.loaded_plugins == []
      assert length(final_state.quarantined_plugins) == 1
      assert match?({:on_ready_crashed, _}, hd(final_state.quarantined_plugins).reason)
    end

    test "L-12: full happy path — plugin discovered, loaded, and ready" do
      Application.put_env(:peripheral_plugins, :inbeam_apps, [:peripheral_telemetry])
      Application.put_env(:peripheral_plugins, :include_plugins, [])
      Application.put_env(:peripheral_plugins, :exclude_plugins, [])
      Application.put_env(:peripheral_telemetry, :plugin_module, GoodPlugin)

      on_exit(fn -> Application.delete_env(:peripheral_telemetry, :plugin_module) end)

      {:ok, state, {:continue, :on_ready}} = Loader.init([])
      assert length(state.loaded_plugins) == 1

      {:noreply, final_state} = Loader.handle_continue(:on_ready, state)

      assert length(final_state.loaded_plugins) == 1
      assert final_state.quarantined_plugins == []
      assert hd(final_state.loaded_plugins).module == GoodPlugin
    end
  end

  describe "decisions.deploy closure" do
    test "rejects malformed XML with a structured parse error" do
      facade = Loader.facade_for_plugin("dmn-deploy-test")

      result = facade.decisions.deploy.(["not xml at all"])

      assert {:error,
              {:dmn_parse_error, %{source_index: 1, code: :dmn_parse_error, metadata: metadata}}} =
               result

      assert is_map(metadata)
    end

    test "rejects partially invalid batch — halts at first malformed source" do
      facade = Loader.facade_for_plugin("dmn-deploy-test-partial")

      valid_xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <definitions xmlns="https://www.omg.org/spec/DMN/20191111/MODEL/"
        id="def_valid" name="Valid" namespace="https://example.com/dmn/valid">
        <decision id="Decision_1" name="Simple">
          <literalExpression><text>42</text></literalExpression>
        </decision>
      </definitions>
      """

      result = facade.decisions.deploy.([valid_xml, "not xml either"])

      assert {:error, {:dmn_parse_error, %{source_index: 2}}} = result
    end
  end

  # -- Helpers ---------------------------------------------------------------

  defp save_and_restore_plugin_env(_context) do
    prev_apps = Application.get_env(:peripheral_plugins, :inbeam_apps)
    prev_include = Application.get_env(:peripheral_plugins, :include_plugins)
    prev_exclude = Application.get_env(:peripheral_plugins, :exclude_plugins)

    on_exit(fn ->
      restore_or_delete(:peripheral_plugins, :inbeam_apps, prev_apps)
      restore_or_delete(:peripheral_plugins, :include_plugins, prev_include)
      restore_or_delete(:peripheral_plugins, :exclude_plugins, prev_exclude)
      Registry.reset_state()
      Loader.register_builtin_capabilities()
    end)

    :ok
  end

  defp restore_or_delete(app, key, nil), do: Application.delete_env(app, key)
  defp restore_or_delete(app, key, value), do: Application.put_env(app, key, value)
end
