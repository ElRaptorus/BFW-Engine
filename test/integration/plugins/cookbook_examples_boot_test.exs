defmodule BfwEngine.Integration.CookbookExamplesBootTest do
  @moduledoc """
  Acceptance (ii): every remaining cookbook example boots into a real engine
  and registers the capabilities its README claims.
  """

  use BfwEngine.IntegrationCase, async: false

  alias BfwEngine.Events.EngineEventBus
  alias BfwEngine.Plugins.Loader
  alias BfwEngine.Test.CookbookPluginHarness
  alias BfwEngine.Types.Event

  @compile {:no_warn_undefined,
            [
              Examples.ServiceTaskHandlers.Echo.EchoPlugin,
              Examples.ServiceTaskHandlers.HttpEnrichment.HttpEnrichmentPlugin,
              Examples.ServiceTaskHandlers.WebhookCallback.WebhookCallbackPlugin,
              Examples.ServiceTaskHandlers.RabbitmqRoundtrip.RabbitmqPlugin,
              Examples.ServiceTaskHandlers.PythonScript.PythonScriptPlugin,
              Examples.ServiceTaskHandlers.NodeScript.NodeScriptPlugin,
              Examples.EventSinks.StructuredLogger.LoggerPlugin,
              Examples.EventSinks.DatadogMetrics.DatadogPlugin,
              Examples.EventSinks.Sse.SsePlugin,
              Examples.Plugins.CustomValidators.ValidatorsPlugin,
              Examples.Plugins.LocalScriptRunner.ScriptRunnerPlugin,
              Examples.Plugins.LifecycleAware.LifecyclePlugin,
              Examples.Plugins.ApiConsumer.ApiConsumerPlugin,
              Examples.Plugins.GithubBpmnDeployer.GithubBpmnDeployerPlugin,
              Examples.Plugins.Combined.MetricsPipeline.MetricsPipelinePlugin,
              IncidentReporter,
              Examples.Plugins.Combined.RabbitmqToEngine.RabbitmqOrchestratorPlugin,
              Examples.Plugins.Adhoc.AiToolbox.AiToolboxPlugin,
              Examples.Plugins.RestApiExtension.EchoPlugin,
              MyCompany.LdapPlugin,
              MyCompany.CompanyGraphPlugin,
              Examples.BusinessRules.DecisionAnalytics.DecisionAnalyticsPlugin,
              Examples.BusinessRules.ExplainDecision.ExplainDecisionPlugin,
              Examples.BusinessRules.DecisionTracePublisher.TracePublisherPlugin,
              Examples.BusinessRules.DecisionServiceSmokeTester.SmokeTesterPlugin,
              Examples.BusinessRules.DecisionRegressionTester.RegressionTesterPlugin,
              Examples.BusinessRules.DecisionAuditReporter.DecisionAuditReporterPlugin,
              Examples.BusinessRules.DrdChainOrchestrator.DrdChainOrchestratorPlugin,
              Examples.BusinessRules.BoxedExpressionShowcase.BoxedShowcasePlugin,
              Examples.EventSinks.WebhookForwarder.WebhookPlugin,
              Examples.Plugins.QuarantineDemo.QuarantineDemoPlugin
            ]}

  test "every remaining cookbook example boots and registers claimed capabilities" do
    Enum.each(CookbookPluginHarness.example_rows(), fn row ->
      try do
        CookbookPluginHarness.boot_and_assert(row)
      rescue
        exception ->
          flunk("cookbook example #{row.name} failed: #{Exception.message(exception)}")
      end
    end)
  end

  test "SSE plugin streams one engine event frame over GET /events/stream" do
    row = CookbookPluginHarness.sse_row()
    CookbookPluginHarness.require_example_files(row)

    facade = Loader.facade_for_plugin("cookbook-sse-stream")
    assert :ok = Examples.EventSinks.Sse.SsePlugin.on_load(facade)

    stream_task =
      Task.async(fn ->
        conn_with_auth(:get, "/events/stream?maxEvents=1")
        |> route()
      end)

    Process.sleep(300)

    :ok =
      EngineEventBus.publish(%Event.EngineStarted{
        engine_id: "cookbook-sse",
        engine_name: "cookbook",
        version: "0.0.0-test",
        started_at: DateTime.utc_now()
      })

    conn = Task.await(stream_task, 5_000)
    assert conn.status == 200
    assert conn.resp_body =~ "data: "
    assert conn.resp_body =~ "cookbook-sse"
  end
end
