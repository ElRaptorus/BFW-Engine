defmodule BfwEngine.Types do
  @moduledoc """
  Namespace for every cross-cutting, behaviour-free struct /
  type alias in the Engine.

  Every type lives in its own module under this namespace; this
  module itself has no code.

  Per-subject modules arrive with their owning feature:

    * `BfwEngine.Types.Identity` — JWT-derived identity claim (§13).
    * `BfwEngine.Types.Token` — process execution token.
    * `BfwEngine.Types.PayloadEnvelope` — `{data, metadata}` wrapper.
    * `BfwEngine.Types.Event.*` — one struct per `:telemetry` event.
    * `BfwEngine.Types.Error` — canonical tagged-error tuples.

  They are added during Phase 1+. Phase 0 only establishes the app.
  """

  use Boundary,
    deps: [],
    exports: [
      Event.ActivityCompensated,
      Event.AdHocActivityActivated,
      Event.AdHocSubProcessCompleted,
      Event.CallActivityChildStarted,
      Event.CompensationTriggered,
      Event.DataObjectWritten,
      Event.DecisionDefinitionDeployed,
      Event.DecisionDefinitionUndeployed,
      Event.DecisionEvaluated,
      Event.EngineOverloaded,
      Event.EngineRecovered,
      Event.EngineShutdown,
      Event.EngineStarted,
      Event.EscalationRaised,
      Event.EventSubprocessTriggered,
      Event.FlowNodeInstanceFinished,
      Event.FlowNodeInstanceStarted,
      Event.FlowNodeInstanceStateChanged,
      Event.MessageArrived,
      Event.MessagePublished,
      Event.MultiInstanceCompleted,
      Event.MultiInstanceStarted,
      Event.PluginAsyncFlowNodeRehydrated,
      Event.PluginQuarantined,
      Event.ProcessDefinitionDeployed,
      Event.ProcessDefinitionDisabled,
      Event.ProcessDefinitionEnabled,
      Event.ProcessDefinitionUndeployed,
      Event.ProcessInstanceRetried,
      Event.ProcessInstanceStateChanged,
      Event.SignalArrived,
      Event.SignalPublished,
      Event.SinkFailed,
      Event.SubProcessChildStarted,
      Event.TimerFired,
      Event.TransactionCancelled,
      Event.UserTaskCreated,
      Event.UserTaskFinished,
      Event.UserTaskValidationFailed,
      FinalToken,
      Identity,
      Token,
      Wire
    ]
end
