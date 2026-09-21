for module <- [
      BfwEngine.Types.Event.SinkFailed,
      BfwEngine.Types.Event.EngineStarted,
      BfwEngine.Types.Event.EngineShutdown,
      BfwEngine.Types.Event.EngineOverloaded,
      BfwEngine.Types.Event.EngineRecovered,
      BfwEngine.Types.Event.PluginQuarantined,
      BfwEngine.Types.Event.ProcessInstanceStateChanged,
      BfwEngine.Types.Event.FlowNodeInstanceStarted,
      BfwEngine.Types.Event.FlowNodeInstanceFinished,
      BfwEngine.Types.Event.FlowNodeInstanceStateChanged,
      BfwEngine.Types.Event.MultiInstanceStarted,
      BfwEngine.Types.Event.MultiInstanceCompleted,
      BfwEngine.Types.Event.UserTaskCreated,
      BfwEngine.Types.Event.UserTaskFinished,
      BfwEngine.Types.Event.UserTaskValidationFailed,
      BfwEngine.Types.Event.PluginAsyncFlowNodeRehydrated,
      BfwEngine.Types.Event.CallActivityChildStarted,
      BfwEngine.Types.Event.SubProcessChildStarted,
      BfwEngine.Types.Event.DataObjectWritten,
      BfwEngine.Types.Event.ProcessDefinitionDeployed,
      BfwEngine.Types.Event.ProcessDefinitionUndeployed,
      BfwEngine.Types.Event.ProcessDefinitionEnabled,
      BfwEngine.Types.Event.ProcessDefinitionDisabled,
      BfwEngine.Types.Event.DecisionDefinitionDeployed,
      BfwEngine.Types.Event.DecisionDefinitionUndeployed,
      BfwEngine.Types.Event.DecisionEvaluated,
      BfwEngine.Types.Event.ProcessInstanceRetried,
      BfwEngine.Types.Event.TimerFired,
      BfwEngine.Types.Event.MessagePublished,
      BfwEngine.Types.Event.MessageArrived,
      BfwEngine.Types.Event.SignalPublished,
      BfwEngine.Types.Event.SignalArrived,
      BfwEngine.Types.Event.EscalationRaised,
      BfwEngine.Types.Event.CompensationTriggered,
      BfwEngine.Types.Event.ActivityCompensated,
      BfwEngine.Types.Event.TransactionCancelled,
      BfwEngine.Types.Event.EventSubprocessTriggered,
      BfwEngine.Types.Event.AdHocActivityActivated,
      BfwEngine.Types.Event.AdHocSubProcessCompleted,
      BfwEngine.Types.Token,
      BfwEngine.Types.FinalToken,
      BfwEngine.Types.Identity
    ] do
  defimpl Jason.Encoder, for: module do
    def encode(struct, opts) do
      struct
      |> BfwEngine.Types.Wire.struct_to_camel_map()
      |> Jason.Encode.map(opts)
    end
  end
end
