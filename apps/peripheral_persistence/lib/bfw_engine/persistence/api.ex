defmodule BfwEngine.Persistence.Api do
  @moduledoc """
  The single Ash domain hosting every engine resource.

  The Ash *Code Interface* exposed on this domain is the
  `BfwEngine.Api` shared service layer used both by the HTTP wire
  surface (`api_web`) and by in-BEAM plugins. Plugins bypass HTTP
  entirely — they call the resource actions as regular Elixir functions.

  Phase 0 ships the execution-state tables (`process_instances`,
  `flow_node_instances`, `gateway_pending_arrivals`). Catalog and
  audit tables land in Phase 1.
  """

  use Ash.Domain,
    otp_app: :peripheral_persistence,
    validate_config_inclusion?: false

  authorization do
    authorize :by_default
  end

  resources do
    resource BfwEngine.Persistence.Resources.Process
    resource BfwEngine.Persistence.Resources.ProcessVersion
    resource BfwEngine.Persistence.Resources.ProcessInstance
    resource BfwEngine.Persistence.Resources.FlowNodeInstance
    resource BfwEngine.Persistence.Resources.GatewayPendingArrival
    resource BfwEngine.Persistence.Resources.DataObject
    resource BfwEngine.Persistence.Resources.DataObjectWrite
    resource BfwEngine.Persistence.Resources.DecisionDefinition
    resource BfwEngine.Persistence.Resources.DecisionVersion
    resource BfwEngine.Persistence.Resources.Message
    resource BfwEngine.Persistence.Resources.PendingMessage
    resource BfwEngine.Persistence.Resources.Signal
    resource BfwEngine.Persistence.Resources.PendingSignal
    resource BfwEngine.Persistence.Resources.TimerStartSchedule
  end
end
