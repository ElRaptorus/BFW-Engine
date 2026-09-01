defmodule EvilEngine.Test.CookbookPluginHarness do
  @moduledoc """
  Sequential real-engine boot helpers for cookbook examples.

  Each row batch-compiles the example with `Examples.Shared.ExampleCompiler`
  (Mix-style `Kernel.ParallelCompiler`, not per-file `Code.require_file/1`),
  calls `on_load` (and optional `on_ready`) through `Loader.facade_for_plugin/1`,
  then asserts Registry capabilities and/or `EngineEventBus.list_sinks/0`.
  Cleanup unregisters capabilities and stops named Agents. Does not call
  `EngineEventBus.reset_state/0` between rows.
  """

  import ExUnit.Assertions

  alias EvilEngine.Auth.ProviderRegistry
  alias EvilEngine.Events.EngineEventBus
  alias EvilEngine.Plugins.Loader
  alias EvilEngine.Plugins.Registry
  alias EvilEngine.Types.Event

  @compile {:no_warn_undefined, Examples.Shared.ExampleCompiler}

  alias Examples.Shared.ExampleCompiler

  @examples_root Path.expand("../../examples/plugins", __DIR__)

  @type expected_capability ::
          {:service_task_handler, String.t()}
          | {:named_script, String.t()}
          | {:rest_api_extension, String.t()}
          | {:auth_provider, module()}
          | {:event_sink, String.t()}

  @type example_row :: %{
          required(:name) => String.t(),
          required(:relative_root) => String.t(),
          required(:plugin_module) => module(),
          required(:expected) => :ok | :quarantine,
          required(:expected_capabilities) => [expected_capability()],
          optional(:extra_require) => [String.t()],
          optional(:skip_on_ready) => boolean(),
          optional(:named_processes) => [module()],
          optional(:setup) => :github_env | :incident_reporter_in_memory | :auth_reset
        }

  @doc "Returns the cookbook rows that must boot against a live engine."
  @spec example_rows() :: [example_row()]
  def example_rows do
    [
      %{
        name: "echo",
        relative_root: "service_task_handlers/echo",
        plugin_module: Examples.ServiceTaskHandlers.Echo.EchoPlugin,
        expected: :ok,
        expected_capabilities: [{:service_task_handler, "echo"}],
        named_processes: [Examples.ServiceTaskHandlers.Echo.EchoFacadeStore]
      },
      %{
        name: "http_enrichment",
        relative_root: "service_task_handlers/http_enrichment",
        plugin_module: Examples.ServiceTaskHandlers.HttpEnrichment.HttpEnrichmentPlugin,
        expected: :ok,
        expected_capabilities: [{:service_task_handler, "http_enrichment"}],
        named_processes: [Examples.ServiceTaskHandlers.HttpEnrichment.HttpEnrichmentFacadeStore]
      },
      %{
        name: "async_webhook_callback",
        relative_root: "service_task_handlers/async_webhook_callback",
        plugin_module: Examples.ServiceTaskHandlers.WebhookCallback.WebhookCallbackPlugin,
        expected: :ok,
        expected_capabilities: [{:service_task_handler, "webhook_callback"}],
        named_processes: [
          Examples.ServiceTaskHandlers.WebhookCallback.WebhookCallbackFacadeStore,
          Examples.ServiceTaskHandlers.WebhookCallback.WebhookCallbackPlugin
        ]
      },
      %{
        name: "async_rabbitmq_roundtrip",
        relative_root: "service_task_handlers/async_rabbitmq_roundtrip",
        plugin_module: Examples.ServiceTaskHandlers.RabbitmqRoundtrip.RabbitmqPlugin,
        expected: :ok,
        expected_capabilities: [{:service_task_handler, "rabbitmq"}],
        named_processes: [
          Examples.ServiceTaskHandlers.RabbitmqRoundtrip.RabbitmqFacadeStore,
          Examples.ServiceTaskHandlers.RabbitmqRoundtrip.RabbitmqPlugin
        ]
      },
      %{
        name: "python_script",
        relative_root: "service_task_handlers/python_script",
        plugin_module: Examples.ServiceTaskHandlers.PythonScript.PythonScriptPlugin,
        expected: :ok,
        expected_capabilities: [{:service_task_handler, "python_script"}],
        extra_require: [Path.join(@examples_root, "shared/script_sandbox.ex")],
        named_processes: [
          Examples.ServiceTaskHandlers.PythonScript.PythonScriptFacadeStore,
          Examples.ServiceTaskHandlers.PythonScript.PythonScriptPlugin
        ]
      },
      %{
        name: "node_script",
        relative_root: "service_task_handlers/node_script",
        plugin_module: Examples.ServiceTaskHandlers.NodeScript.NodeScriptPlugin,
        expected: :ok,
        expected_capabilities: [{:service_task_handler, "node_script"}],
        extra_require: [Path.join(@examples_root, "shared/script_sandbox.ex")],
        named_processes: [
          Examples.ServiceTaskHandlers.NodeScript.NodeScriptFacadeStore,
          Examples.ServiceTaskHandlers.NodeScript.NodeScriptPlugin
        ]
      },
      %{
        name: "structured_logger",
        relative_root: "event_sinks/structured_logger",
        plugin_module: Examples.EventSinks.StructuredLogger.LoggerPlugin,
        expected: :ok,
        expected_capabilities: [{:event_sink, "structured_logger"}]
      },
      %{
        name: "datadog_metrics",
        relative_root: "event_sinks/datadog_metrics",
        plugin_module: Examples.EventSinks.DatadogMetrics.DatadogPlugin,
        expected: :ok,
        expected_capabilities: [{:event_sink, "datadog"}]
      },
      %{
        name: "sse",
        relative_root: "event_sinks/sse",
        plugin_module: Examples.EventSinks.Sse.SsePlugin,
        expected: :ok,
        expected_capabilities: [
          {:event_sink, "sse"},
          {:rest_api_extension, "/events"}
        ],
        named_processes: [Examples.EventSinks.Sse.ConnectionHub]
      },
      %{
        name: "custom_validators",
        relative_root: "named_scripts/custom_validators",
        plugin_module: Examples.Plugins.CustomValidators.ValidatorsPlugin,
        expected: :ok,
        expected_capabilities: [
          {:named_script, "validate_payload"},
          {:named_script, "convert_currency"},
          {:named_script, "idempotency_guard"}
        ]
      },
      %{
        name: "local_script_runner",
        relative_root: "named_scripts/local_script_runner",
        plugin_module: Examples.Plugins.LocalScriptRunner.ScriptRunnerPlugin,
        expected: :ok,
        expected_capabilities: [{:named_script, "local_script"}],
        extra_require: [Path.join(@examples_root, "shared/script_sandbox.ex")]
      },
      %{
        name: "lifecycle_aware",
        relative_root: "lifecycle_and_api/lifecycle_aware",
        plugin_module: Examples.Plugins.LifecycleAware.LifecyclePlugin,
        expected: :ok,
        expected_capabilities: [{:event_sink, "lifecycle-demo-noop-sink"}]
      },
      %{
        name: "api_consumer",
        relative_root: "lifecycle_and_api/api_consumer",
        plugin_module: Examples.Plugins.ApiConsumer.ApiConsumerPlugin,
        expected: :ok,
        expected_capabilities: [],
        skip_on_ready: true,
        named_processes: [Examples.Plugins.ApiConsumer.FacadeStore]
      },
      %{
        name: "github_bpmn_deployer",
        relative_root: "lifecycle_and_api/github_bpmn_deployer",
        plugin_module: Examples.Plugins.GithubBpmnDeployer.GithubBpmnDeployerPlugin,
        expected: :ok,
        expected_capabilities: [],
        skip_on_ready: true,
        setup: :github_env,
        named_processes: [Examples.Plugins.GithubBpmnDeployer.FacadeStore]
      },
      %{
        name: "metrics_pipeline",
        relative_root: "combined/metrics_pipeline",
        plugin_module: Examples.Plugins.Combined.MetricsPipeline.MetricsPipelinePlugin,
        expected: :ok,
        expected_capabilities: [
          {:event_sink, "metrics_collector"},
          {:service_task_handler, "aggregate_metrics"}
        ],
        named_processes: [Examples.Plugins.Combined.MetricsPipeline.FacadeStore]
      },
      %{
        name: "incident_reporter",
        relative_root: "combined/incident_reporter",
        plugin_module: IncidentReporter,
        expected: :ok,
        expected_capabilities: [{:event_sink, "incident_reporter"}],
        setup: :incident_reporter_in_memory,
        named_processes: [IncidentReporter.RetryConsumer]
      },
      %{
        name: "rabbitmq_to_engine",
        relative_root: "combined/rabbitmq_to_engine",
        plugin_module: Examples.Plugins.Combined.RabbitmqToEngine.RabbitmqOrchestratorPlugin,
        expected: :ok,
        expected_capabilities: [{:event_sink, "orchestrator_metrics"}],
        skip_on_ready: true,
        named_processes: [Examples.Plugins.Combined.RabbitmqToEngine.FacadeStore]
      },
      %{
        name: "ai_toolbox",
        relative_root: "adhoc/ai_toolbox",
        plugin_module: Examples.Plugins.Adhoc.AiToolbox.AiToolboxPlugin,
        expected: :ok,
        expected_capabilities: [{:event_sink, "ai-toolbox"}]
      },
      %{
        name: "rest_echo",
        relative_root: "rest_api_extension/echo",
        plugin_module: Examples.Plugins.RestApiExtension.EchoPlugin,
        expected: :ok,
        expected_capabilities: [{:rest_api_extension, "/echo-ext"}]
      },
      %{
        name: "ldap",
        relative_root: "auth_providers/ldap",
        plugin_module: MyCompany.LdapPlugin,
        expected: :ok,
        expected_capabilities: [{:auth_provider, MyCompany.LdapAuthProvider}],
        setup: :auth_reset
      },
      %{
        name: "companygraph",
        relative_root: "auth_providers/companygraph",
        plugin_module: MyCompany.CompanyGraphPlugin,
        expected: :ok,
        expected_capabilities: [{:auth_provider, MyCompany.CompanyGraphAuthProvider}],
        setup: :auth_reset
      },
      %{
        name: "decision_analytics",
        relative_root: "business_rules/decision_analytics",
        plugin_module: Examples.BusinessRules.DecisionAnalytics.DecisionAnalyticsPlugin,
        expected: :ok,
        expected_capabilities: [{:event_sink, "decision_analytics"}],
        named_processes: [Examples.BusinessRules.DecisionAnalytics.AnalyticsCollector]
      },
      %{
        name: "explain_decision",
        relative_root: "business_rules/explain_decision",
        plugin_module: Examples.BusinessRules.ExplainDecision.ExplainDecisionPlugin,
        expected: :ok,
        expected_capabilities: [{:named_script, "explain_decision"}]
      },
      %{
        name: "decision_trace_publisher",
        relative_root: "business_rules/decision_trace_publisher",
        plugin_module: Examples.BusinessRules.DecisionTracePublisher.TracePublisherPlugin,
        expected: :ok,
        expected_capabilities: [{:event_sink, "decision_trace_publisher"}]
      },
      %{
        name: "decision_service_smoke_tester",
        relative_root: "business_rules/decision_service_smoke_tester",
        plugin_module: Examples.BusinessRules.DecisionServiceSmokeTester.SmokeTesterPlugin,
        expected: :ok,
        expected_capabilities: [],
        skip_on_ready: true,
        named_processes: [Examples.BusinessRules.DecisionServiceSmokeTester.FacadeStore]
      },
      %{
        name: "decision_regression_tester",
        relative_root: "business_rules/decision_regression_tester",
        plugin_module: Examples.BusinessRules.DecisionRegressionTester.RegressionTesterPlugin,
        expected: :ok,
        expected_capabilities: [],
        skip_on_ready: true,
        named_processes: [Examples.BusinessRules.DecisionRegressionTester.FacadeStore]
      },
      %{
        name: "decision_audit_reporter",
        relative_root: "business_rules/decision_audit_reporter",
        plugin_module: Examples.BusinessRules.DecisionAuditReporter.DecisionAuditReporterPlugin,
        expected: :ok,
        expected_capabilities: [{:event_sink, "decision_audit_reporter"}],
        skip_on_ready: true,
        named_processes: [
          Examples.BusinessRules.DecisionAuditReporter.FacadeStore,
          Examples.BusinessRules.DecisionAuditReporter.EventTracker
        ]
      },
      %{
        name: "drd_chain_orchestrator",
        relative_root: "business_rules/drd_chain_orchestrator",
        plugin_module: Examples.BusinessRules.DrdChainOrchestrator.DrdChainOrchestratorPlugin,
        expected: :ok,
        expected_capabilities: [],
        skip_on_ready: true,
        named_processes: [Examples.BusinessRules.DrdChainOrchestrator.FacadeStore]
      },
      %{
        name: "boxed_expression_showcase",
        relative_root: "business_rules/boxed_expression_showcase",
        plugin_module: Examples.BusinessRules.BoxedExpressionShowcase.BoxedShowcasePlugin,
        expected: :ok,
        expected_capabilities: [],
        skip_on_ready: true,
        named_processes: [Examples.BusinessRules.BoxedExpressionShowcase.FacadeStore]
      },
      %{
        name: "webhook_forwarder",
        relative_root: "event_sinks/webhook_forwarder",
        plugin_module: Examples.EventSinks.WebhookForwarder.WebhookPlugin,
        expected: :ok,
        expected_capabilities: [{:event_sink, "webhook_forwarder"}]
      },
      %{
        name: "quarantine_demo",
        relative_root: "lifecycle_and_api/quarantine_demo",
        plugin_module: Examples.Plugins.QuarantineDemo.QuarantineDemoPlugin,
        expected: :quarantine,
        expected_capabilities: []
      }
    ]
  end

  @doc "Returns the SSE catalogue row used by the streamed-frame integration test."
  @spec sse_row() :: example_row()
  def sse_row do
    Enum.find(example_rows(), &(&1.name == "sse"))
  end

  @doc "Requires example sources, boots the plugin, asserts registration, then cleans up."
  @spec boot_and_assert(example_row()) :: :ok
  def boot_and_assert(row) do
    require_example_files(row)
    apply_row_setup(row)

    plugin_name = "cookbook-" <> row.name
    facade = Loader.facade_for_plugin(plugin_name)
    plugin_module = row.plugin_module

    try do
      case row.expected do
        :quarantine ->
          assert_quarantine_row(row, plugin_name, facade, plugin_module)

        :ok ->
          assert :ok = plugin_module.on_load(facade)

          unless Map.get(row, :skip_on_ready, false) do
            assert :ok = plugin_module.on_ready(facade)
          end

          assert_expected_capabilities(plugin_name, row.expected_capabilities)
      end

      :ok
    after
      Registry.unregister_plugin_capabilities(plugin_name)
      Enum.each(Map.get(row, :named_processes, []), &stop_named_process/1)
      restore_row_setup(row)
      ProviderRegistry.reset_to_default()
    end
  end

  @doc "Batch-compiles cookbook `lib/` files plus any shared extras."
  @spec require_example_files(example_row()) :: :ok
  def require_example_files(row) do
    Code.require_file(Path.join(@examples_root, "shared/example_compiler.ex"))

    extra_files = Map.get(row, :extra_require, [])
    Enum.each(extra_files, &Code.require_file/1)

    library_root = Path.join(@examples_root, row.relative_root)
    library_files = Path.wildcard(Path.join(library_root, "lib/**/*.ex"))

    ExampleCompiler.compile_files(library_files)
  end

  @github_environment_keys ~w(GITHUB_BPMN_REPO_OWNER GITHUB_BPMN_REPO_NAME GITHUB_ACCESS_TOKEN)

  defp apply_row_setup(%{setup: :github_env}) do
    previous =
      Map.new(@github_environment_keys, fn key -> {key, System.get_env(key)} end)

    Process.put({__MODULE__, :github_environment_previous}, previous)
    System.put_env("GITHUB_BPMN_REPO_OWNER", "cookbook-ci")
    System.put_env("GITHUB_BPMN_REPO_NAME", "cookbook-ci")
    System.put_env("GITHUB_ACCESS_TOKEN", "cookbook-ci-token")
    :ok
  end

  defp apply_row_setup(%{setup: :incident_reporter_in_memory}) do
    previous = Application.get_env(:incident_reporter, :message_bus_adapter)
    Process.put({__MODULE__, :incident_reporter_adapter_previous}, previous)

    Application.put_env(
      :incident_reporter,
      :message_bus_adapter,
      IncidentReporter.MessageBus.InMemoryAdapter
    )

    :ok
  end

  defp apply_row_setup(%{setup: :auth_reset}) do
    ProviderRegistry.reset_to_default()
    :ok
  end

  defp apply_row_setup(_row), do: :ok

  defp restore_row_setup(%{setup: :github_env}) do
    case Process.get({__MODULE__, :github_environment_previous}) do
      nil ->
        :ok

      previous ->
        Enum.each(previous, fn
          {key, nil} -> System.delete_env(key)
          {key, value} -> System.put_env(key, value)
        end)

        Process.delete({__MODULE__, :github_environment_previous})
        :ok
    end
  end

  defp restore_row_setup(%{setup: :incident_reporter_in_memory}) do
    previous = Process.get({__MODULE__, :incident_reporter_adapter_previous})
    restore_env(:incident_reporter, :message_bus_adapter, previous)
    Process.delete({__MODULE__, :incident_reporter_adapter_previous})
    :ok
  end

  defp restore_row_setup(_row), do: :ok

  defp assert_quarantine_row(_row, plugin_name, facade, plugin_module) do
    assert {:error, :intentional_quarantine} = plugin_module.on_load(facade)

    refute_plugin_capabilities(plugin_name)

    loaded_names = Enum.map(Loader.loaded_plugins(), & &1.name)
    refute plugin_name in loaded_names

    assert_loader_init_emits_plugin_quarantined()
  end

  defp refute_plugin_capabilities(plugin_name) do
    capability_types = [
      :service_task_handler,
      :named_script,
      :rest_api_extension,
      :auth_provider
    ]

    Enum.each(capability_types, fn capability_type ->
      matching =
        Enum.filter(Registry.list_capabilities(capability_type), fn capability ->
          capability.plugin_name == plugin_name
        end)

      assert matching == []
    end)
  end

  defp assert_loader_init_emits_plugin_quarantined do
    collector_name = :"cookbook_quarantine_capture_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Agent.start_link(fn -> [] end, name: collector_name)

    sink_name = "cookbook-quarantine-capture-#{System.unique_integer([:positive])}"

    :ok =
      EngineEventBus.register_sink(
        sink_name,
        EvilEngine.Test.CookbookPluginHarness.QuarantineCaptureSink,
        collector: collector_name
      )

    previous_inbeam = Application.get_env(:peripheral_plugins, :inbeam_apps)
    previous_include = Application.get_env(:peripheral_plugins, :include_plugins)
    previous_exclude = Application.get_env(:peripheral_plugins, :exclude_plugins)
    previous_plugin_module = Application.get_env(:peripheral_telemetry, :plugin_module)

    try do
      Application.put_env(:peripheral_plugins, :inbeam_apps, [:peripheral_telemetry])
      Application.put_env(:peripheral_plugins, :include_plugins, [])
      Application.put_env(:peripheral_plugins, :exclude_plugins, [])

      Application.put_env(
        :peripheral_telemetry,
        :plugin_module,
        Examples.Plugins.QuarantineDemo.QuarantineDemoPlugin
      )

      {:ok, loader_state, _continue} = Loader.init([])

      assert length(loader_state.quarantined_plugins) >= 1
      assert wait_for_plugin_quarantined_event(collector_name)

      :ok
    after
      restore_env(:peripheral_plugins, :inbeam_apps, previous_inbeam)
      restore_env(:peripheral_plugins, :include_plugins, previous_include)
      restore_env(:peripheral_plugins, :exclude_plugins, previous_exclude)
      restore_env(:peripheral_telemetry, :plugin_module, previous_plugin_module)
      stop_named_process(collector_name)
    end
  end

  defp assert_expected_capabilities(plugin_name, expected_capabilities) do
    Enum.each(expected_capabilities, fn
      {:service_task_handler, implementation} ->
        assert capability_present?(
                 :service_task_handler,
                 plugin_name,
                 :implementation,
                 implementation
               ),
               "missing service_task_handler #{implementation} for #{plugin_name}"

      {:named_script, script_key} ->
        assert capability_present?(:named_script, plugin_name, :script_key, script_key),
               "missing named_script #{script_key} for #{plugin_name}"

      {:rest_api_extension, prefix} ->
        assert capability_present?(:rest_api_extension, plugin_name, :prefix, prefix),
               "missing rest_api_extension #{prefix} for #{plugin_name}"

      {:auth_provider, module} ->
        assert ProviderRegistry.active_provider() == module

      {:event_sink, sink_name} ->
        assert Enum.any?(EngineEventBus.list_sinks(), &(&1.name == sink_name)),
               "missing event sink #{sink_name}; have #{inspect(EngineEventBus.list_sinks())}"
    end)
  end

  defp capability_present?(capability_type, plugin_name, descriptor_key, expected_value) do
    Enum.any?(Registry.list_capabilities(capability_type), fn capability ->
      capability.plugin_name == plugin_name and
        capability.descriptor[descriptor_key] == expected_value
    end)
  end

  defp stop_named_process(process_name) do
    case Process.whereis(process_name) do
      nil ->
        :ok

      pid ->
        Process.unlink(pid)
        monitor_reference = Process.monitor(pid)
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor_reference, :process, ^pid, _reason} -> :ok
        after
          1_000 -> :ok
        end
    end
  end

  defp wait_for_plugin_quarantined_event(collector_name) do
    Enum.reduce_while(1..40, false, fn _attempt, _acc ->
      captured = Agent.get(collector_name, & &1)

      if Enum.any?(captured, &match?(%Event.PluginQuarantined{}, &1)) do
        {:halt, true}
      else
        Process.sleep(50)
        {:cont, false}
      end
    end)
  end

  defp restore_env(application, key, nil), do: Application.delete_env(application, key)
  defp restore_env(application, key, value), do: Application.put_env(application, key, value)
end

defmodule EvilEngine.Test.CookbookPluginHarness.QuarantineCaptureSink do
  @moduledoc false

  @behaviour EvilEngine.Plugin.EventSink

  alias EvilEngine.Types.Event

  @impl true
  def init(options) do
    {:ok, %{collector: Keyword.fetch!(options, :collector)}}
  end

  @impl true
  def accepts?(%Event.PluginQuarantined{}), do: true
  def accepts?(_event), do: false

  @impl true
  def handle_event(event, state) do
    Agent.update(state.collector, fn events -> [event | events] end)
    {:ok, state}
  end

  @impl true
  def handle_shutdown(_state), do: :ok
end
