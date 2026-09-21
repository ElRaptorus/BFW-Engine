defmodule BfwEngine.Execution.EventSubprocessResolver do
  @moduledoc """
  Pure resolution of **error** and **escalation** raises against the Event
  Subprocess (ESP) start events declared in a scope.

  Both resolvers implement the "specific code beats catch-all" tiebreak
  **within** the ESP candidate set (ESP-D6). Proximity (boundary-on-host tested
  before the scope ESP, scope ESP before outward propagation) is enforced by the
  *call sites* in `ProcessInstance` — this module only ranks candidates that are
  all peers in one scope.

  The candidates are `BfwEngine.Execution.EventSubprocessTrigger` structs held
  in the scope PI's `event_subprocess_triggers` map; their `error_code` /
  `escalation_code` are resolved once at registration time (from inline codes or
  global `<bpmn:error>` / `<bpmn:escalation>` definitions).
  """

  alias BfwEngine.Execution.EventSubprocessTrigger

  @type error_info :: %{optional(:error_code) => String.t() | nil, optional(any()) => any()}
  @type escalation_info :: %{
          optional(:escalation_code) => String.t() | nil,
          optional(any()) => any()
        }

  @doc """
  Finds the ESP error start that catches `error_info`, or `:none`.

  A trigger with a specific `error_code` matching the raised code wins over a
  catch-all (`error_code: nil`) trigger. Only `armed?` `:error` triggers are
  considered. Error ESP starts are always interrupting (validator-enforced).
  """
  @spec find_matching_error_start(
          %{optional(String.t()) => EventSubprocessTrigger.t()},
          error_info()
        ) ::
          {:ok, EventSubprocessTrigger.t()} | :none
  def find_matching_error_start(triggers, error_info) do
    raised_code = Map.get(error_info, :error_code) || Map.get(error_info, "error_code")

    candidates =
      triggers
      |> Map.values()
      |> Enum.filter(&(&1.trigger_kind == :error and &1.armed?))

    rank_by_specificity(candidates, & &1.error_code, raised_code)
  end

  @doc """
  Finds the ESP escalation start that catches `escalation_info`, or `:none`.

  Specific `escalation_code` match beats catch-all. Only `armed?` `:escalation`
  triggers are considered.
  """
  @spec find_matching_escalation_start(
          %{optional(String.t()) => EventSubprocessTrigger.t()},
          escalation_info()
        ) :: {:ok, EventSubprocessTrigger.t()} | :none
  def find_matching_escalation_start(triggers, escalation_info) do
    raised_code =
      Map.get(escalation_info, :escalation_code) || Map.get(escalation_info, "escalation_code")

    candidates =
      triggers
      |> Map.values()
      |> Enum.filter(&(&1.trigger_kind == :escalation and &1.armed?))

    rank_by_specificity(candidates, & &1.escalation_code, raised_code)
  end

  @doc """
  Finds the ESP compensation start in the scope, or `:none`.

  Compensation ESP starts are always interrupting (COMP-D5). Only `armed?`
  `:compensation` triggers are considered.
  """
  @spec find_matching_compensation_start(%{optional(String.t()) => EventSubprocessTrigger.t()}) ::
          {:ok, EventSubprocessTrigger.t()} | :none
  def find_matching_compensation_start(triggers) do
    candidate =
      triggers
      |> Map.values()
      |> Enum.find(&(&1.trigger_kind == :compensation and &1.armed?))

    case candidate do
      nil -> :none
      trigger -> {:ok, trigger}
    end
  end

  # Specific code (equal to the raised code) wins over a catch-all (nil code).
  defp rank_by_specificity(candidates, code_getter, raised_code) do
    specific =
      Enum.find(candidates, fn trigger ->
        code = code_getter.(trigger)
        not is_nil(code) and code == raised_code
      end)

    catch_all = Enum.find(candidates, fn trigger -> is_nil(code_getter.(trigger)) end)

    case specific || catch_all do
      nil -> :none
      trigger -> {:ok, trigger}
    end
  end
end
