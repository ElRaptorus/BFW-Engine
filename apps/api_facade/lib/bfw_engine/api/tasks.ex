defmodule BfwEngine.Api.Tasks do
  @moduledoc """
  User, manual, and service task operations.
  Callers use `BfwEngine.Api`.
  """

  require Ash.Query

  alias BfwEngine.Api.ProcessInstances
  alias BfwEngine.Api.Validation
  alias BfwEngine.Execution
  alias BfwEngine.Execution.PayloadCap
  alias BfwEngine.Persistence.Resources

  @domain BfwEngine.Persistence.Api

  @doc """
  List Service Task flow node instances that are still waiting for a plugin.

  `implementations` is the list of BPMN `implementation` strings to match.
  A row is included only when the flow node type is `service_task`, the
  state is `waiting`, the owning process instance is `running`, and
  `type_properties["implementation"]` is one of the given strings.
  The returned `input_token` is `type_properties["mapped_input"]`, or the
  stored `input_token` when that field is absent.
  Order is `started_at` ascending, then `id` ascending.
  """
  @type waiting_service_task :: %{
          flow_node_instance_id: String.t(),
          process_instance_id: String.t(),
          flow_node_id: String.t(),
          implementation: String.t(),
          input_token: map() | nil
        }

  @spec list_waiting_service_tasks([String.t()]) ::
          {:ok, [waiting_service_task()]} | {:error, :invalid_implementations | term()}
  def list_waiting_service_tasks(implementations) when is_list(implementations) do
    if Enum.all?(implementations, &is_binary/1) do
      read_waiting_service_tasks(implementations)
    else
      {:error, :invalid_implementations}
    end
  end

  def list_waiting_service_tasks(_implementations), do: {:error, :invalid_implementations}

  defp read_waiting_service_tasks([]), do: {:ok, []}

  defp read_waiting_service_tasks(implementations) do
    Resources.FlowNodeInstance
    |> Ash.Query.filter(flow_node_type == "service_task" and state == "waiting")
    |> Ash.Query.sort(started_at: :asc, id: :asc)
    |> Ash.Query.load(:process_instance)
    |> Ash.read(domain: @domain, authorize?: false)
    |> case do
      {:ok, rows} -> {:ok, waiting_service_task_rows(rows, MapSet.new(implementations))}
      {:error, reason} -> {:error, reason}
    end
  end

  defp waiting_service_task_rows(rows, allowed_implementations) do
    Enum.flat_map(rows, fn row ->
      implementation = implementation_from_type_properties(row.type_properties)

      if match?(%{state: "running"}, row.process_instance) and is_binary(implementation) and
           MapSet.member?(allowed_implementations, implementation) do
        [
          %{
            flow_node_instance_id: row.id,
            process_instance_id: row.process_instance_id,
            flow_node_id: row.flow_node_id,
            implementation: implementation,
            input_token: waiting_service_task_input_token(row)
          }
        ]
      else
        []
      end
    end)
  end

  defp implementation_from_type_properties(type_properties) when is_map(type_properties) do
    Map.get(type_properties, "implementation") || Map.get(type_properties, :implementation)
  end

  defp implementation_from_type_properties(_type_properties), do: nil

  # Rows parked before mapped_input existed keep the mapped payload in input_token.
  defp waiting_service_task_input_token(row) do
    type_properties = if is_map(row.type_properties), do: row.type_properties, else: %{}

    cond do
      Map.has_key?(type_properties, "mapped_input") -> type_properties["mapped_input"]
      Map.has_key?(type_properties, :mapped_input) -> Map.get(type_properties, :mapped_input)
      true -> row.input_token
    end
  end

  @doc """
  Complete a waiting User Task.

  `values` is the field-value object (`nil` becomes `%{}`). `opts` accepts
  `action_id:` (`nil`, or a non-blank string of at most 255 characters).
  Body checks run first, then the payload cap and FNI existence. Lane access
  runs next, before the type check (`user_task`, else
  `{:error, :not_a_user_task}`) and the waiting-state check, so a caller who
  cannot observe the lane receives `{:error, :not_found}`.
  """
  @spec finish_user_task(String.t(), term(), struct(), keyword()) ::
          :ok
          | {:error, term()}
          | {:error, :payload_too_large, map()}
          | BfwEngine.Api.forbidden_error()
  def finish_user_task(flow_node_instance_id, values, identity, opts \\ []) do
    action_id = Keyword.get(opts, :action_id)

    with {:ok, values} <- normalize_finish_values(values),
         :ok <- validate_finish_action_id(action_id),
         :ok <- PayloadCap.check(values, field: :values),
         {:ok, flow_node_instance} <-
           ProcessInstances.get_flow_node_instance(flow_node_instance_id),
         :ok <- Validation.check_lane_access(flow_node_instance, identity, opts),
         :ok <- validate_flow_node_type(flow_node_instance, "user_task"),
         :ok <- validate_fni_waiting(flow_node_instance) do
      Execution.finish_user_task(
        flow_node_instance.process_instance_id,
        flow_node_instance_id,
        values,
        identity,
        action_id: action_id
      )
    end
  end

  defp normalize_finish_values(nil), do: {:ok, %{}}

  defp normalize_finish_values(values) when is_map(values) and not is_struct(values),
    do: {:ok, values}

  defp normalize_finish_values(_values), do: {:error, :invalid_values}

  defp validate_finish_action_id(nil), do: :ok

  defp validate_finish_action_id(action_id) when is_binary(action_id) do
    if String.trim(action_id) != "" and String.length(action_id) <= 255 do
      :ok
    else
      {:error, :invalid_action_id}
    end
  end

  defp validate_finish_action_id(_action_id), do: {:error, :invalid_action_id}

  @doc """
  Cancel a waiting User Task and abort the whole process instance tree.

  Validates FNI existence, then lane access, then type (`user_task`, else
  `{:error, :not_a_user_task}`) and waiting state, before delegating to
  Execution. A caller who cannot observe the lane receives
  `{:error, :not_found}`.
  """
  @spec cancel_user_task(String.t(), String.t() | nil, struct(), keyword()) ::
          :ok | {:error, term()} | BfwEngine.Api.forbidden_error()
  def cancel_user_task(flow_node_instance_id, reason, identity, opts \\ []) do
    cancel_inbox_task(flow_node_instance_id, "user_task", reason, identity, opts)
  end

  @doc """
  Confirm a waiting Manual Task (`bfw:requireConfirmation`).

  Takes no payload: the token the Manual Task entered with continues
  unchanged. Validates FNI existence, then lane access, then type
  (`manual_task`, else `{:error, :not_a_manual_task}`) and waiting state,
  before delegating to Execution. A caller who cannot observe the lane
  receives `{:error, :not_found}`.
  """
  @spec confirm_manual_task(String.t(), struct(), keyword()) ::
          :ok | {:error, term()} | BfwEngine.Api.forbidden_error()
  def confirm_manual_task(flow_node_instance_id, identity, opts \\ []) do
    with {:ok, flow_node_instance} <-
           ProcessInstances.get_flow_node_instance(flow_node_instance_id),
         :ok <- Validation.check_lane_access(flow_node_instance, identity, opts),
         :ok <- validate_flow_node_type(flow_node_instance, "manual_task"),
         :ok <- validate_fni_waiting(flow_node_instance) do
      Execution.confirm_manual_task(
        flow_node_instance.process_instance_id,
        flow_node_instance_id,
        identity
      )
    end
  end

  @doc """
  Cancel a waiting Manual Task and abort the whole process instance tree.

  Validates FNI existence, then lane access, then type (`manual_task`, else
  `{:error, :not_a_manual_task}`) and waiting state, before delegating to
  Execution. A caller who cannot observe the lane receives
  `{:error, :not_found}`.
  """
  @spec cancel_manual_task(String.t(), String.t() | nil, struct(), keyword()) ::
          :ok | {:error, term()} | BfwEngine.Api.forbidden_error()
  def cancel_manual_task(flow_node_instance_id, reason, identity, opts \\ []) do
    cancel_inbox_task(flow_node_instance_id, "manual_task", reason, identity, opts)
  end

  defp cancel_inbox_task(flow_node_instance_id, expected_type, reason, identity, opts) do
    with {:ok, flow_node_instance} <-
           ProcessInstances.get_flow_node_instance(flow_node_instance_id),
         :ok <- Validation.check_lane_access(flow_node_instance, identity, opts),
         :ok <- validate_flow_node_type(flow_node_instance, expected_type),
         :ok <- validate_fni_waiting(flow_node_instance) do
      Execution.cancel_inbox_task(
        flow_node_instance.process_instance_id,
        flow_node_instance_id,
        reason,
        identity
      )
    end
  end

  @doc "Complete a parked async Service Task with a result."
  defdelegate finish_async_service_task(flow_node_instance_id, result), to: Execution

  @doc "Fail a parked async Service Task with an error code and message."
  defdelegate fail_async_service_task(flow_node_instance_id, error_code, error_message),
    to: Execution

  defp validate_flow_node_type(%{flow_node_type: expected_type}, expected_type), do: :ok
  defp validate_flow_node_type(_flow_node_instance, "user_task"), do: {:error, :not_a_user_task}

  defp validate_flow_node_type(_flow_node_instance, "manual_task"),
    do: {:error, :not_a_manual_task}

  defp validate_fni_waiting(%{state: "waiting"}), do: :ok
  defp validate_fni_waiting(%{state: "finished"}), do: {:error, :fni_already_finished}
  defp validate_fni_waiting(%{state: "aborted"}), do: {:error, :fni_already_aborted}
  defp validate_fni_waiting(%{state: "interrupted"}), do: {:error, :fni_already_interrupted}
  defp validate_fni_waiting(%{state: "fatal"}), do: {:error, :fni_already_fatal}
  defp validate_fni_waiting(_), do: {:error, :fni_not_waiting}
end
