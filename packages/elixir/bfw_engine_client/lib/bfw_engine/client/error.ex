defmodule BfwEngine.Client.Error do
  @moduledoc """
  The single exception struct raised by every `BfwEngine.Client` operation
  when the Engine responds with a non-2xx status, or when a GraphQL response
  carries an `errors[]` entry.

  `reason` is an atom drawn from a fixed, compile-time table mirroring the
  domain error classes in the TypeScript client
  (`packages/js/client/src/errors/error-mapper.ts`). Unknown wire codes fall
  back to a reason derived from the HTTP status code, and finally to
  `:engine_error`.

  Transport-level failures (connection refused, timeout, TLS errors) are
  **not** wrapped in this struct — the internal request helper returns the
  underlying `Req` exception unchanged so callers can distinguish "the
  Engine answered with an error" from "the Engine could not be reached".
  """

  @type reason ::
          :bad_request
          | :unauthorized
          | :forbidden
          | :not_found
          | :conflict
          | :validation_error
          | :internal_engine_error
          | :service_unavailable
          | :engine_error
          | :payload_too_large
          | :rate_limited
          | :engine_at_capacity
          | :process_not_found
          | :no_active_version
          | :process_disabled
          | :active_instances_exist
          | :ambiguous_start_event
          | :start_event_not_found
          | :no_start_event
          | :no_executable_process
          | :contract_violation
          | :process_instance_already_terminal
          | :process_instance_not_terminal
          | :fni_not_waiting
          | :parse_error
          | :deploy_validation_failed
          | :linter_gate_failed
          | :version_exists
          | :process_instance_not_retriable
          | :incompatible_version_migration
          | :retry_checkpoint_is_join_gateway
          | :retry_checkpoint_is_ebg_loser
          | :retry_checkpoint_is_mi_iteration
          | :retry_checkpoint_is_non_retryable
          | :decision_definition_not_found
          | :retry_checkpoint_inside_transaction
          | :retry_inside_transaction_scope
          | :retry_checkpoint_inside_adhoc_subprocess
          | :retry_inside_adhoc_subprocess
          | :not_a_timer_event
          | :dispatch_failed
          | :no_matching_condition
          | :no_decisions
          | :graphql_depth_limit
          | :graphql_complexity_limit
          | :graphql_introspection_disabled
          | :decision_definition_disabled
          | :dmn_evaluation_error
          | :decision_version_not_found
          | :dmn_cycle_error
          | :bkm_not_found
          | :decision_service_not_found
          | :decision_service_validation_error
          | :ambiguous_decision
          | :input_value_violation
          | :missing_service_input
          | :dmn_parse_error
          | :decision_version_exists

  defexception [:status, :code, :reason, :message, :body]

  @type t :: %__MODULE__{
          status: pos_integer() | nil,
          code: String.t(),
          reason: reason(),
          message: String.t(),
          body: term()
        }

  @doc false
  def message(%__MODULE__{message: message}), do: message

  # Mirrors every `case '<code>':` branch in
  # packages/js/client/src/errors/error-mapper.ts's `mapByErrorCode/3`. The
  # atom is the snake_cased error-class name that branch instantiates; where
  # several wire codes map to the same TypeScript class, they share one atom.
  @code_to_reason %{
    "payload_too_large" => :payload_too_large,
    "rate_limited" => :rate_limited,
    "engine_at_capacity" => :engine_at_capacity,
    "service_unavailable" => :service_unavailable,
    "not_found" => :not_found,
    "metrics_disabled" => :not_found,
    "forbidden" => :forbidden,
    "process_not_found" => :process_not_found,
    "no_active_version" => :no_active_version,
    "process_disabled" => :process_disabled,
    "active_instances_exist" => :active_instances_exist,
    "ambiguous_start_event" => :ambiguous_start_event,
    "start_event_not_found" => :start_event_not_found,
    "no_start_event" => :no_start_event,
    "no_executable_process" => :no_executable_process,
    "contract_violation" => :contract_violation,
    "process_already_terminal" => :process_instance_already_terminal,
    "process_instance_not_terminal" => :process_instance_not_terminal,
    "fni_not_waiting" => :fni_not_waiting,
    "fni_not_active" => :fni_not_waiting,
    "fni_already_finished" => :fni_not_waiting,
    "fni_already_aborted" => :fni_not_waiting,
    "fni_already_interrupted" => :fni_not_waiting,
    "fni_already_fatal" => :fni_not_waiting,
    "parse_error" => :parse_error,
    "validation_failed" => :deploy_validation_failed,
    "linter_gate_failed" => :linter_gate_failed,
    "version_exists" => :version_exists,
    "process_instance_not_retriable" => :process_instance_not_retriable,
    "version_migration_incompatible" => :incompatible_version_migration,
    "incompatible_version_migration" => :incompatible_version_migration,
    "retry_checkpoint_is_join_gateway" => :retry_checkpoint_is_join_gateway,
    "retry_checkpoint_is_ebg_loser" => :retry_checkpoint_is_ebg_loser,
    "retry_checkpoint_is_mi_iteration" => :retry_checkpoint_is_mi_iteration,
    "retry_checkpoint_is_non_retryable" => :retry_checkpoint_is_non_retryable,
    "target_version_not_cached" => :validation_error,
    "version_disabled" => :process_disabled,
    "not_applicable" => :validation_error,
    "enable_failed" => :validation_error,
    "disable_failed" => :validation_error,
    "decision_not_found" => :decision_definition_not_found,
    "retry_checkpoint_inside_transaction" => :retry_checkpoint_inside_transaction,
    "retry_inside_transaction_scope" => :retry_inside_transaction_scope,
    "retry_checkpoint_inside_adhoc_subprocess" => :retry_checkpoint_inside_adhoc_subprocess,
    "retry_inside_adhoc_subprocess" => :retry_inside_adhoc_subprocess,
    "not_a_timer_event" => :not_a_timer_event,
    "dispatch_failed" => :dispatch_failed,
    "conflict" => :conflict,
    "bad_request" => :bad_request,
    "no_matching_condition" => :no_matching_condition,
    "no_decisions" => :no_decisions,
    "root_process_instance_not_terminal" => :process_instance_not_terminal,
    "version_not_found" => :not_found,
    "flow_node_instance_not_found" => :not_found,
    "batch_conflict" => :version_exists,
    "graphql_depth_limit" => :graphql_depth_limit,
    "graphql_complexity_limit" => :graphql_complexity_limit,
    "graphql_introspection_disabled" => :graphql_introspection_disabled,
    "decision_definition_not_found" => :decision_definition_not_found,
    "decision_definition_disabled" => :decision_definition_disabled,
    "dmn_evaluation_error" => :dmn_evaluation_error,
    "decision_version_not_found" => :decision_version_not_found,
    "dmn_cycle_error" => :dmn_cycle_error,
    "bkm_not_found" => :bkm_not_found,
    "service_not_found" => :decision_service_not_found,
    "decision_service_validation_error" => :decision_service_validation_error,
    "ambiguous_decision" => :ambiguous_decision,
    "input_value_violation" => :input_value_violation,
    "missing_service_input" => :missing_service_input,
    "dmn_parse_error" => :dmn_parse_error,
    "decision_version_exists" => :decision_version_exists,
    "not_adhoc_subprocess" => :validation_error,
    "adhoc_activity_not_found" => :not_found,
    "adhoc_already_completing" => :validation_error,
    "adhoc_sequential_busy" => :validation_error,
    "adhoc_not_active" => :validation_error,
    "internal_error" => :internal_engine_error
  }

  @status_to_reason %{
    400 => :bad_request,
    401 => :unauthorized,
    403 => :forbidden,
    404 => :not_found,
    409 => :conflict,
    422 => :validation_error,
    500 => :internal_engine_error,
    503 => :engine_at_capacity
  }

  @doc """
  Builds an error struct from a non-2xx HTTP response.

  Reads the wire error code from `body["error"]` and the human-readable
  message from `body["message"]`, falling back to the code and to the HTTP
  status code respectively when either key is absent.
  """
  @spec from_response(pos_integer(), term()) :: t()
  def from_response(status, body) when is_map(body) do
    code = Map.get(body, "error", "unknown")
    message = Map.get(body, "message", code)

    %__MODULE__{
      status: status,
      code: code,
      reason: reason_for_code(code) || reason_for_status(status),
      message: message,
      body: body
    }
  end

  def from_response(status, body) do
    %__MODULE__{
      status: status,
      code: "unknown",
      reason: reason_for_status(status),
      message: "The Engine responded with status #{status}",
      body: body
    }
  end

  @doc """
  Builds an error struct from a single entry of a GraphQL response's
  `errors[]` array (a 200-status response that still carries an error).

  Reads the domain error code from `error["extensions"]["code"]`.
  """
  @spec from_graphql_error(map()) :: t()
  def from_graphql_error(error) when is_map(error) do
    code = get_in(error, ["extensions", "code"]) || "unknown"
    message = Map.get(error, "message") || code

    %__MODULE__{
      status: nil,
      code: code,
      reason: reason_for_code(code) || :engine_error,
      message: message,
      body: error
    }
  end

  defp reason_for_code(code) when is_binary(code) do
    normalized = code |> String.downcase() |> String.replace(" ", "_")
    Map.get(@code_to_reason, normalized)
  end

  defp reason_for_code(_code), do: nil
  defp reason_for_status(status), do: Map.get(@status_to_reason, status, :engine_error)
end
