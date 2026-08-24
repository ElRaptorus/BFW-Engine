defmodule EvilEngine.EngineFacadeTest do
  use ExUnit.Case, async: true

  alias EvilEngine.EngineFacade

  @registration_fields_2arity [
    :register_service_task_handler,
    :register_named_script,
    :register_rest_api_extension
  ]

  @registration_fields_1arity [
    :register_auth_provider
  ]

  describe "struct construction" do
    test "builds with required keys" do
      facade = %EngineFacade{
        engine_id: "e-1",
        engine_name: "test-engine",
        version: "0.0.1"
      }

      assert facade.engine_id == "e-1"
      assert facade.engine_name == "test-engine"
      assert facade.version == "0.0.1"
    end

    test "raises when required key is missing" do
      assert_raise ArgumentError, ~r/the following keys must also be given/, fn ->
        struct!(EngineFacade, %{engine_id: "e-1"})
      end
    end

    test "namespace sub-structs are initialized with defaults" do
      facade = %EngineFacade{
        engine_id: "e-1",
        engine_name: "test",
        version: "0.0.1"
      }

      assert %EngineFacade.Processes{} = facade.processes
      assert %EngineFacade.ProcessInstances{} = facade.process_instances
      assert %EngineFacade.UserTasks{} = facade.user_tasks
      assert %EngineFacade.ServiceTasks{} = facade.service_tasks
      assert %EngineFacade.FlowNodeInstances{} = facade.flow_node_instances
      assert %EngineFacade.DataObjects{} = facade.data_objects
      assert %EngineFacade.Decisions{} = facade.decisions
      assert %EngineFacade.Graphql{} = facade.graphql
      assert %EngineFacade.Timers{} = facade.timers
    end
  end

  describe "noop defaults" do
    setup do
      facade = %EngineFacade{
        engine_id: "e-1",
        engine_name: "test",
        version: "0.0.1"
      }

      %{facade: facade}
    end

    test "2-arity registration noops return {:error, :not_wired}", %{facade: f} do
      for field <- @registration_fields_2arity do
        closure = Map.fetch!(f, field)

        assert closure.("key", SomeModule) == {:error, :not_wired},
               "expected #{field} noop to return {:error, :not_wired}"
      end
    end

    test "1-arity registration noops return {:error, :not_wired}", %{facade: f} do
      for field <- @registration_fields_1arity do
        closure = Map.fetch!(f, field)

        assert closure.(SomeModule) == {:error, :not_wired},
               "expected #{field} noop to return {:error, :not_wired}"
      end
    end

    test "noop_register_event_sink returns {:error, :not_wired}", %{facade: f} do
      assert f.register_event_sink.("x", SomeModule, []) == {:error, :not_wired}
    end

    test "noop_publish_event returns :ok", %{facade: f} do
      assert f.publish_event.(%{}) == :ok
    end

    test "noop_get_config returns nil", %{facade: f} do
      assert f.get_config.(:anything) == nil
    end

    test "namespace noop: user_tasks.finish returns {:error, :not_wired}", %{facade: f} do
      assert f.user_tasks.finish.("fni-1", %{}, %{}) == {:error, :not_wired}
    end

    test "namespace noop: user_tasks.cancel returns {:error, :not_wired}", %{facade: f} do
      assert f.user_tasks.cancel.("fni-1", "reason", %{}) == {:error, :not_wired}
    end

    test "namespace noop: service_tasks.finish_async returns {:error, :not_wired}", %{facade: f} do
      assert f.service_tasks.finish_async.("fni-1", %{}) == {:error, :not_wired}
    end

    test "namespace noop: service_tasks.fail_async returns {:error, :not_wired}", %{facade: f} do
      assert f.service_tasks.fail_async.("fni-1", "ERR", "msg") == {:error, :not_wired}
    end

    test "namespace noop: processes.get returns {:error, :not_wired}", %{facade: f} do
      assert f.processes.get.("model-1") == {:error, :not_wired}
    end

    test "namespace noop: process_instances.get returns {:error, :not_wired}", %{facade: f} do
      assert f.process_instances.get.("pi-1") == {:error, :not_wired}
    end

    test "namespace noop: flow_node_instances.get returns {:error, :not_wired}", %{facade: f} do
      assert f.flow_node_instances.get.("fni-1") == {:error, :not_wired}
    end

    test "namespace noop: flow_node_instances.list_for_process_instance returns {:error, :not_wired}",
         %{facade: f} do
      assert f.flow_node_instances.list_for_process_instance.("pi-1") == {:error, :not_wired}
    end

    test "namespace noop: data_objects.get returns {:error, :not_wired}", %{facade: f} do
      assert f.data_objects.get.("do-1") == {:error, :not_wired}
    end

    test "namespace noop: graphql.query returns {:error, :not_wired}", %{facade: f} do
      assert f.graphql.query.("{ processModels { id } }", %{}) == {:error, :not_wired}
    end

    test "namespace noop: decisions.list returns {:error, :not_wired}", %{facade: f} do
      assert f.decisions.list.() == {:error, :not_wired}
    end

    test "namespace noop: decisions.get returns {:error, :not_wired}", %{facade: f} do
      assert f.decisions.get.("model-1") == {:error, :not_wired}
    end

    test "namespace noop: decisions.evaluate returns {:error, :not_wired}", %{facade: f} do
      assert f.decisions.evaluate.("model-1", %{}, []) == {:error, :not_wired}
    end

    test "namespace noop: decisions.evaluate_service returns {:error, :not_wired}", %{facade: f} do
      assert f.decisions.evaluate_service.("model-1", "svc-1", %{}, []) == {:error, :not_wired}
    end

    test "namespace noop: decisions.get_versions returns {:error, :not_wired}", %{facade: f} do
      assert f.decisions.get_versions.("model-1") == {:error, :not_wired}
    end

    test "namespace noop: decisions.get_xml returns {:error, :not_wired}", %{facade: f} do
      assert f.decisions.get_xml.("model-1") == {:error, :not_wired}
    end

    test "namespace noop: decisions.enable returns {:error, :not_wired}", %{facade: f} do
      assert f.decisions.enable.("model-1") == {:error, :not_wired}
    end

    test "namespace noop: decisions.deploy returns {:error, :not_wired}", %{facade: f} do
      assert f.decisions.deploy.(["<xml/>"]) == {:error, :not_wired}
    end

    test "namespace noop: decisions.delete_version returns {:error, :not_wired}", %{facade: f} do
      assert f.decisions.delete_version.("model-1", "1.0.0") == {:error, :not_wired}
    end

    test "namespace noop: decisions.undeploy returns {:error, :not_wired}", %{facade: f} do
      assert f.decisions.undeploy.("model-1") == {:error, :not_wired}
    end

    test "namespace noop: processes.list returns {:error, :not_wired}", %{facade: f} do
      assert f.processes.list.() == {:error, :not_wired}
    end

    test "namespace noop: processes.undeploy returns {:error, :not_wired}", %{facade: f} do
      assert f.processes.undeploy.("model-1") == {:error, :not_wired}
    end

    test "namespace noop: timers.trigger_event returns {:error, :not_wired}", %{facade: f} do
      assert f.timers.trigger_event.("fni-1") == {:error, :not_wired}
    end
  end

  describe "closure arities" do
    setup do
      facade = %EngineFacade{
        engine_id: "e-1",
        engine_name: "test",
        version: "0.0.1"
      }

      %{facade: facade}
    end

    test "all 2-arity registration fields are functions of arity 2", %{facade: f} do
      for field <- @registration_fields_2arity do
        assert is_function(Map.fetch!(f, field), 2),
               "expected #{field} to be a function of arity 2"
      end
    end

    test "all 1-arity registration fields are functions of arity 1", %{facade: f} do
      for field <- @registration_fields_1arity do
        assert is_function(Map.fetch!(f, field), 1),
               "expected #{field} to be a function of arity 1"
      end
    end

    test "register_event_sink is a function of arity 3", %{facade: f} do
      assert is_function(f.register_event_sink, 3)
    end

    test "publish_event is a function of arity 1", %{facade: f} do
      assert is_function(f.publish_event, 1)
    end

    test "get_config is a function of arity 1", %{facade: f} do
      assert is_function(f.get_config, 1)
    end

    test "user_tasks.finish is a function of arity 3", %{facade: f} do
      assert is_function(f.user_tasks.finish, 3)
    end

    test "user_tasks.cancel is a function of arity 3", %{facade: f} do
      assert is_function(f.user_tasks.cancel, 3)
    end

    test "service_tasks.finish_async is a function of arity 2", %{facade: f} do
      assert is_function(f.service_tasks.finish_async, 2)
    end

    test "service_tasks.fail_async is a function of arity 3", %{facade: f} do
      assert is_function(f.service_tasks.fail_async, 3)
    end

    test "processes.get is a function of arity 1", %{facade: f} do
      assert is_function(f.processes.get, 1)
    end

    test "processes.deploy is a function of arity 1", %{facade: f} do
      assert is_function(f.processes.deploy, 1)
    end

    test "processes.start is a function of arity 1", %{facade: f} do
      assert is_function(f.processes.start, 1)
    end

    test "process_instances.get is a function of arity 1", %{facade: f} do
      assert is_function(f.process_instances.get, 1)
    end

    test "process_instances.abort is a function of arity 2", %{facade: f} do
      assert is_function(f.process_instances.abort, 2)
    end

    test "flow_node_instances.get is a function of arity 1", %{facade: f} do
      assert is_function(f.flow_node_instances.get, 1)
    end

    test "flow_node_instances.list_for_process_instance is a function of arity 1", %{facade: f} do
      assert is_function(f.flow_node_instances.list_for_process_instance, 1)
    end

    test "data_objects.get is a function of arity 1", %{facade: f} do
      assert is_function(f.data_objects.get, 1)
    end

    test "data_objects.list_for_instance is a function of arity 1", %{facade: f} do
      assert is_function(f.data_objects.list_for_instance, 1)
    end

    test "graphql.query is a function of arity 2", %{facade: f} do
      assert is_function(f.graphql.query, 2)
    end

    test "decisions.list is a function of arity 0", %{facade: f} do
      assert is_function(f.decisions.list, 0)
    end

    test "decisions.get is a function of arity 1", %{facade: f} do
      assert is_function(f.decisions.get, 1)
    end

    test "decisions.get_latest_version is a function of arity 1", %{facade: f} do
      assert is_function(f.decisions.get_latest_version, 1)
    end

    test "decisions.deploy is a function of arity 1", %{facade: f} do
      assert is_function(f.decisions.deploy, 1)
    end

    test "decisions.evaluate is a function of arity 3", %{facade: f} do
      assert is_function(f.decisions.evaluate, 3)
    end

    test "decisions.evaluate_service is a function of arity 4", %{facade: f} do
      assert is_function(f.decisions.evaluate_service, 4)
    end

    test "decisions.get_versions is a function of arity 1", %{facade: f} do
      assert is_function(f.decisions.get_versions, 1)
    end

    test "decisions.get_xml is a function of arity 1", %{facade: f} do
      assert is_function(f.decisions.get_xml, 1)
    end

    test "decisions.enable is a function of arity 1", %{facade: f} do
      assert is_function(f.decisions.enable, 1)
    end

    test "decisions.disable is a function of arity 1", %{facade: f} do
      assert is_function(f.decisions.disable, 1)
    end

    test "decisions.delete_version is a function of arity 2", %{facade: f} do
      assert is_function(f.decisions.delete_version, 2)
    end

    test "decisions.undeploy is a function of arity 1", %{facade: f} do
      assert is_function(f.decisions.undeploy, 1)
    end

    test "processes.list is a function of arity 0", %{facade: f} do
      assert is_function(f.processes.list, 0)
    end

    test "processes.undeploy is a function of arity 1", %{facade: f} do
      assert is_function(f.processes.undeploy, 1)
    end

    test "timers.trigger_event is a function of arity 1", %{facade: f} do
      assert is_function(f.timers.trigger_event, 1)
    end
  end

  describe "wired closures" do
    test "closures can be replaced with real functions" do
      captured_calls = :ets.new(:test_calls, [:set, :public])

      facade = %EngineFacade{
        engine_id: "e-1",
        engine_name: "test",
        version: "0.0.1",
        register_service_task_handler: fn implementation, handler ->
          :ets.insert(captured_calls, {:register_sth, implementation, handler})
          :ok
        end,
        register_named_script: fn script_key, handler ->
          :ets.insert(captured_calls, {:register_ns, script_key, handler})
          :ok
        end,
        publish_event: fn event ->
          :ets.insert(captured_calls, {:publish, event})
          :ok
        end,
        get_config: fn key ->
          if key == :engine_id, do: "e-1", else: nil
        end
      }

      assert facade.register_service_task_handler.("echo", MyHandler) == :ok
      assert facade.register_named_script.("validate", MyScript) == :ok
      assert facade.publish_event.(%{type: :test}) == :ok
      assert facade.get_config.(:engine_id) == "e-1"
      assert facade.get_config.(:unknown) == nil

      assert [{:register_sth, "echo", MyHandler}] = :ets.lookup(captured_calls, :register_sth)
      assert [{:register_ns, "validate", MyScript}] = :ets.lookup(captured_calls, :register_ns)

      :ets.delete(captured_calls)
    end

    test "namespace closures can be wired with real functions" do
      facade = %EngineFacade{
        engine_id: "e-1",
        engine_name: "test",
        version: "0.0.1",
        service_tasks: %EngineFacade.ServiceTasks{
          finish_async: fn fni_id, result -> {:ok, {fni_id, result}} end,
          fail_async: fn fni_id, code, msg -> {:ok, {fni_id, code, msg}} end
        },
        processes: %EngineFacade.Processes{
          get: fn model_id -> {:ok, %{id: model_id}} end
        }
      }

      assert {:ok, {"fni-1", %{a: 1}}} = facade.service_tasks.finish_async.("fni-1", %{a: 1})

      assert {:ok, {"fni-1", "ERR", "msg"}} =
               facade.service_tasks.fail_async.("fni-1", "ERR", "msg")

      assert {:ok, %{id: "model-x"}} = facade.processes.get.("model-x")
    end
  end
end
