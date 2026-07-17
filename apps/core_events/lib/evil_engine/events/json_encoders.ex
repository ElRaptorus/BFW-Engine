for module <- [
      EvilEngine.Types.Event.SinkFailed,
      EvilEngine.Types.Event.EngineStarted,
      EvilEngine.Types.Event.EngineShutdown,
      EvilEngine.Types.Event.EngineOverloaded,
      EvilEngine.Types.Event.EngineRecovered,
      EvilEngine.Types.Event.PluginQuarantined,
      EvilEngine.Types.Event.ProcessInstanceStateChanged,
      EvilEngine.Types.Event.FlowNodeInstanceStarted,
      EvilEngine.Types.Event.FlowNodeInstanceFinished,
      EvilEngine.Types.Event.FlowNodeInstanceStateChanged,
      EvilEngine.Types.Event.MultiInstanceStarted,
      EvilEngine.Types.Event.MultiInstanceCompleted,
      EvilEngine.Types.Event.UserTaskCreated,
      EvilEngine.Types.Event.UserTaskFinished,
      EvilEngine.Types.Event.UserTaskValidationFailed,
      EvilEngine.Types.Event.PluginAsyncFlowNodeRehydrated,
      EvilEngine.Types.Event.CallActivityChildStarted,
      EvilEngine.Types.Event.SubProcessChildStarted,
      EvilEngine.Types.Event.DataObjectWritten,
      EvilEngine.Types.Event.ProcessDefinitionDeployed,
      EvilEngine.Types.Event.ProcessDefinitionUndeployed,
      EvilEngine.Types.Event.ProcessDefinitionEnabled,
      EvilEngine.Types.Event.ProcessDefinitionDisabled,
      EvilEngine.Types.Event.DecisionDefinitionDeployed,
      EvilEngine.Types.Event.DecisionDefinitionUndeployed,
      EvilEngine.Types.Event.DecisionEvaluated,
      EvilEngine.Types.Event.ProcessInstanceRetried,
      EvilEngine.Types.Event.TimerArmed,
      EvilEngine.Types.Event.TimerFired,
      EvilEngine.Types.Event.TimerCancelled,
      EvilEngine.Types.Event.MessagePublished,
      EvilEngine.Types.Event.MessageArrived,
      EvilEngine.Types.Event.SignalPublished,
      EvilEngine.Types.Event.SignalArrived,
      EvilEngine.Types.Event.EscalationRaised,
      EvilEngine.Types.Event.CompensationTriggered,
      EvilEngine.Types.Event.ActivityCompensated,
      EvilEngine.Types.Event.TransactionCancelled,
      EvilEngine.Types.Event.EventSubprocessTriggered,
      EvilEngine.Types.Token,
      EvilEngine.Types.FinalToken,
      EvilEngine.Types.Identity
    ] do
  defimpl Jason.Encoder, for: module do
    def encode(struct, opts) do
      struct
      |> EvilEngine.Types.Wire.struct_to_camel_map()
      |> Jason.Encode.map(opts)
    end
  end
end
