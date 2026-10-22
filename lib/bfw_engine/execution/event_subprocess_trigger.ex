defmodule BfwEngine.Execution.EventSubprocessTrigger do
  @moduledoc """
  Per-scope-PI record describing one Event Subprocess (ESP) declared in the
  scope's model. Held in `ProcessInstance.State.event_subprocess_triggers`,
  keyed by the ESP shell node id.

  A trigger lies **dormant** until its source fires:

  - `:message` / `:signal` — registered in `MessageSubscriptions` /
    `SignalSubscriptions` with kind `:event_subprocess_start`; `subscription_id`
    holds the registry handle. Message triggers additionally carry a
    `correlation_value` evaluated at scope activation.
  - `:timer` — armed via the `Scheduler`; `timer_ref` holds the handle.
  - `:conditional` — evaluated PI-internally on every scope FNI state change;
    `last_condition_value` supports edge-triggering (`false → true`).
  - `:error` / `:escalation` — reactive; resolved at raise time by
    `EventSubprocessResolver`. No subscription/timer handle.

  `is_interrupting` selects the fire semantics (§3.4a vs §3.4b). `armed?` is
  `true` while the trigger may fire; interrupting fire tears down all triggers,
  non-interrupting fire re-arms (message/signal stay, timer cycle re-arms,
  conditional re-arms with edge semantics, date/duration timer is one-shot).
  """

  alias BfwEngine.BPMN.Model.EventDefinition

  @type trigger_kind ::
          :message | :signal | :timer | :error | :escalation | :conditional | :compensation

  @type t :: %__MODULE__{
          subprocess_node_id: String.t(),
          start_event_id: String.t(),
          trigger_kind: trigger_kind(),
          is_interrupting: boolean(),
          message_name: String.t() | nil,
          signal_name: String.t() | nil,
          error_code: String.t() | nil,
          escalation_code: String.t() | nil,
          condition_expression: String.t() | nil,
          timer_spec: EventDefinition.Timer.t() | nil,
          correlation_value: term(),
          subscription_id: String.t() | nil,
          timer_ref: reference() | nil,
          armed?: boolean(),
          last_condition_value: boolean()
        }

  defstruct [
    :subprocess_node_id,
    :start_event_id,
    :trigger_kind,
    :is_interrupting,
    :message_name,
    :signal_name,
    :error_code,
    :escalation_code,
    :condition_expression,
    :timer_spec,
    :correlation_value,
    :subscription_id,
    :timer_ref,
    armed?: true,
    last_condition_value: false
  ]
end
