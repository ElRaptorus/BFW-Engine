defmodule EvilEngine.Persistence.Api do
  @moduledoc """
  The single Ash domain hosting every engine resource.

  The Ash *Code Interface* exposed on this domain is the
  `EvilEngine.Api` shared service layer used both by the HTTP wire
  surface (`api_web`) and by in-BEAM plugins. There is no gRPC sidecar
  host. Plugins bypass HTTP entirely — they call
  the resource actions as regular Elixir functions.

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
    resource EvilEngine.Persistence.Resources.Process
    resource EvilEngine.Persistence.Resources.ProcessVersion
    resource EvilEngine.Persistence.Resources.ProcessInstance
    resource EvilEngine.Persistence.Resources.FlowNodeInstance
    resource EvilEngine.Persistence.Resources.GatewayPendingArrival
    resource EvilEngine.Persistence.Resources.DataObject
    resource EvilEngine.Persistence.Resources.DataObjectWrite
    resource EvilEngine.Persistence.Resources.DecisionDefinition
    resource EvilEngine.Persistence.Resources.DecisionVersion
    resource EvilEngine.Persistence.Resources.Message
    resource EvilEngine.Persistence.Resources.PendingMessage
    resource EvilEngine.Persistence.Resources.Signal
    resource EvilEngine.Persistence.Resources.PendingSignal
    resource EvilEngine.Persistence.Resources.TimerStartSchedule
  end
end
