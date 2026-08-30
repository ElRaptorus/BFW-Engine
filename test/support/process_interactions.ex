defmodule EvilEngine.Test.ProcessInteractions do
  @moduledoc """
  Reusable functions for interacting with running process instances
  across integration, conformance, and load test suites.

  Every function takes explicit IDs and returns tagged tuples.
  Assertions stay in the calling test — this module is pure
  interaction logic.
  """

  require Ash.Query

  alias EvilEngine.Execution
  alias EvilEngine.Persistence.Resources.FlowNodeInstance
  alias EvilEngine.Persistence.Resources.ProcessInstance, as: PiResource

  @doc """
  Finish a waiting UserTask via the REST endpoint.
  """
  @spec finish_user_task(String.t(), String.t(), term(), keyword()) :: :ok | {:error, term()}
  def finish_user_task(_process_instance_id, flow_node_instance_id, result, _identity_or_opts \\ []) do
    json_body = Jason.encode!(%{"result" => result})

    conn =
      Plug.Test.conn(:put, "/user-tasks/#{flow_node_instance_id}/finish", json_body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_test_jwt()}")
      |> send_through_endpoint()

    case conn.status do
      204 -> :ok
      status -> {:error, {status, Jason.decode!(conn.resp_body)}}
    end
  end

  @doc """
  Cancel a waiting UserTask via the REST endpoint.
  """
  @spec cancel_user_task(String.t(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def cancel_user_task(_process_instance_id, flow_node_instance_id, reason, _identity_or_opts \\ []) do
    body = if reason, do: %{"reason" => reason}, else: %{}
    json_body = Jason.encode!(body)

    conn =
      Plug.Test.conn(:put, "/user-tasks/#{flow_node_instance_id}/cancel", json_body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_test_jwt()}")
      |> send_through_endpoint()

    case conn.status do
      204 -> :ok
      status -> {:error, {status, Jason.decode!(conn.resp_body)}}
    end
  end

  @doc """
  Finish a waiting ManualTask (requireConfirmation=true).
  Uses the same `finish_user_task` call with empty result.
  """
  @spec finish_manual_task(String.t(), String.t()) :: :ok | {:error, term()}
  def finish_manual_task(process_instance_id, flow_node_instance_id) do
    finish_user_task(process_instance_id, flow_node_instance_id, %{})
  end

  defp sign_test_jwt do
    secret = Application.get_env(:api_auth, :hs256_secret) || "test_only_secret_at_least_32_bytes!"
    jwk = JOSE.JWK.from_oct(secret)

    claims = %{
      "sub" => "test-user",
      "exp" => DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_unix(),
      "iat" => DateTime.utc_now() |> DateTime.to_unix(),
      "lane:default" => "write"
    }

    {_, compact} = JOSE.JWT.sign(jwk, %{"alg" => "HS256"}, claims) |> JOSE.JWS.compact()
    compact
  end

  defp send_through_endpoint(conn) do
    EvilEngineWeb.Http.Endpoint.call(conn, EvilEngineWeb.Http.Endpoint.init([]))
  end

  @doc """
  Complete an async service task FNI via the execution API.
  """
  @spec finish_async_service_task(String.t(), term()) :: :ok | {:error, term()}
  def finish_async_service_task(flow_node_instance_id, result) do
    Execution.finish_async_service_task(flow_node_instance_id, result)
  end

  @doc """
  Fail an async service task FNI via the execution API.
  """
  @spec fail_async_service_task(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def fail_async_service_task(flow_node_instance_id, code, message) do
    Execution.fail_async_service_task(flow_node_instance_id, code, message)
  end

  @doc """
  Poll the DB until the PI reaches the expected state or timeout.

  Options:
    - `:timeout` — max wait in ms (default 5_000)
    - `:poll_interval` — polling interval in ms (default 50)
  """
  @spec await_process_instance_state(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, :timeout}
  def await_process_instance_state(process_instance_id, expected_state, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    interval = Keyword.get(opts, :poll_interval, 50)
    deadline = System.monotonic_time(:millisecond) + timeout

    do_poll_state(process_instance_id, expected_state, interval, deadline)
  end

  defp do_poll_state(process_instance_id, expected_state, interval, deadline) do
    case query_process_instance_state(process_instance_id) do
      {:ok, ^expected_state} ->
        process_instance = Ash.get!(PiResource, process_instance_id, authorize?: false)
        {:ok, process_instance}

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(interval)
          do_poll_state(process_instance_id, expected_state, interval, deadline)
        end
    end
  end

  defp query_process_instance_state(process_instance_id) do
    case Ash.get(PiResource, process_instance_id, authorize?: false) do
      {:ok, process_instance} -> {:ok, process_instance.state}
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc """
  Query the DB for the first FNI of the given type in `:waiting` state
  for the specified PI.
  """
  @spec find_waiting_fni(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def find_waiting_fni(process_instance_id, flow_node_type) do
    result =
      FlowNodeInstance
      |> Ash.Query.filter(
        process_instance_id == ^process_instance_id and
          flow_node_type == ^flow_node_type and
          state == "waiting"
      )
      |> Ash.Query.limit(1)
      |> Ash.read!(authorize?: false)

    case result do
      [flow_node_instance | _] -> {:ok, flow_node_instance}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Poll the DB until a waiting FNI with the given `flow_node_id` appears for
  the specified process instance, or until the timeout expires.
  """
  @spec await_waiting_fni_by_node_id(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, :timeout}
  def await_waiting_fni_by_node_id(process_instance_id, flow_node_id, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    interval = Keyword.get(opts, :poll_interval, 50)
    deadline = System.monotonic_time(:millisecond) + timeout

    do_poll_waiting_fni_by_node_id(process_instance_id, flow_node_id, interval, deadline)
  end

  defp do_poll_waiting_fni_by_node_id(process_instance_id, flow_node_id, interval, deadline) do
    result =
      FlowNodeInstance
      |> Ash.Query.filter(
        process_instance_id == ^process_instance_id and
          flow_node_id == ^flow_node_id and
          state == "waiting"
      )
      |> Ash.Query.limit(1)
      |> Ash.read!(authorize?: false)

    case result do
      [flow_node_instance | _] ->
        {:ok, flow_node_instance}

      [] ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(interval)
          do_poll_waiting_fni_by_node_id(process_instance_id, flow_node_id, interval, deadline)
        end
    end
  end

  @doc """
  Poll the DB until at least `minimum_count` FNIs with `flow_node_id` are
  `finished`, or until the timeout expires.

  Use this before completing a host activity that has a non-interrupting
  timer boundary: finishing the host cancels the boundary, so the timeout
  path must already have produced its End Event FNI(s).
  """
  @spec await_finished_fni_count_by_node_id(String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, [map()]} | {:error, :timeout}
  def await_finished_fni_count_by_node_id(
        process_instance_id,
        flow_node_id,
        minimum_count,
        opts \\ []
      )
      when is_integer(minimum_count) and minimum_count >= 1 do
    timeout = Keyword.get(opts, :timeout, 5_000)
    interval = Keyword.get(opts, :poll_interval, 50)
    deadline = System.monotonic_time(:millisecond) + timeout

    do_poll_finished_fni_count_by_node_id(
      process_instance_id,
      flow_node_id,
      minimum_count,
      interval,
      deadline
    )
  end

  defp do_poll_finished_fni_count_by_node_id(
         process_instance_id,
         flow_node_id,
         minimum_count,
         interval,
         deadline
       ) do
    matching_flow_node_instances =
      FlowNodeInstance
      |> Ash.Query.filter(
        process_instance_id == ^process_instance_id and
          flow_node_id == ^flow_node_id and
          state == "finished"
      )
      |> Ash.read!(authorize?: false)

    if length(matching_flow_node_instances) >= minimum_count do
      {:ok, matching_flow_node_instances}
    else
      if System.monotonic_time(:millisecond) >= deadline do
        {:error, :timeout}
      else
        Process.sleep(interval)

        do_poll_finished_fni_count_by_node_id(
          process_instance_id,
          flow_node_id,
          minimum_count,
          interval,
          deadline
        )
      end
    end
  end

  @doc """
  Convenience for `await_finished_fni_count_by_node_id/4` with `minimum_count` 1.
  """
  @spec await_finished_fni_by_node_id(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, :timeout}
  def await_finished_fni_by_node_id(process_instance_id, flow_node_id, opts \\ []) do
    case await_finished_fni_count_by_node_id(process_instance_id, flow_node_id, 1, opts) do
      {:ok, [flow_node_instance | _rest]} -> {:ok, flow_node_instance}
      {:error, :timeout} -> {:error, :timeout}
    end
  end

  @doc """
  Poll until a child process instance of `parent_process_instance_id` reaches
  the expected state.

  Options:
    - `:expected_state` — default `"finished"`
    - `:timeout` — max wait in ms (default 10_000)
    - `:poll_interval` — polling interval in ms (default 50)
  """
  @spec await_child_process_instance_state(String.t(), keyword()) ::
          {:ok, map()} | {:error, :timeout}
  def await_child_process_instance_state(parent_process_instance_id, opts \\ []) do
    expected_state = Keyword.get(opts, :expected_state, "finished")
    timeout = Keyword.get(opts, :timeout, 10_000)
    interval = Keyword.get(opts, :poll_interval, 50)
    deadline = System.monotonic_time(:millisecond) + timeout

    do_poll_child_process_instance_state(
      parent_process_instance_id,
      expected_state,
      interval,
      deadline
    )
  end

  defp do_poll_child_process_instance_state(
         parent_process_instance_id,
         expected_state,
         interval,
         deadline
       ) do
    children =
      PiResource
      |> Ash.Query.filter(parent_process_instance_id == ^parent_process_instance_id)
      |> Ash.read!(authorize?: false)

    match = Enum.find(children, fn child -> child.state == expected_state end)

    cond do
      match != nil ->
        {:ok, match}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :timeout}

      true ->
        Process.sleep(interval)

        do_poll_child_process_instance_state(
          parent_process_instance_id,
          expected_state,
          interval,
          deadline
        )
    end
  end

  @doc """
  Re-read a waiting user task FNI and finish it via REST.

  Retries on HTTP 404: a concurrent timer-boundary persist can briefly make
  the FNI invisible to the facade (same class of race as P45).
  """
  @spec finish_waiting_user_task(String.t(), keyword()) :: :ok | {:error, term()}
  def finish_waiting_user_task(process_instance_id, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 10_000)
    result = Keyword.get(opts, :result, %{})
    deadline = System.monotonic_time(:millisecond) + timeout

    do_finish_waiting_user_task(process_instance_id, result, deadline)
  end

  defp do_finish_waiting_user_task(process_instance_id, result, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      case await_waiting_flow_node_instance(process_instance_id, "user_task",
             timeout: min(remaining, 2_000)
           ) do
        {:ok, user_task_flow_node_instance} ->
          case finish_user_task(process_instance_id, user_task_flow_node_instance.id, result) do
            :ok ->
              :ok

            {:error, {404, _body}} ->
              Process.sleep(50)
              do_finish_waiting_user_task(process_instance_id, result, deadline)

            other ->
              other
          end

        {:error, :timeout} ->
          Process.sleep(50)
          do_finish_waiting_user_task(process_instance_id, result, deadline)
      end
    end
  end

  @doc """
  Poll the DB until a waiting FNI of the given type appears, or timeout.
  """
  @spec await_waiting_flow_node_instance(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, :timeout}
  def await_waiting_flow_node_instance(process_instance_id, flow_node_type, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    interval = Keyword.get(opts, :poll_interval, 50)
    deadline = System.monotonic_time(:millisecond) + timeout

    do_poll_waiting_flow_node_instance(process_instance_id, flow_node_type, interval, deadline)
  end

  defp do_poll_waiting_flow_node_instance(process_instance_id, flow_node_type, interval, deadline) do
    case find_waiting_fni(process_instance_id, flow_node_type) do
      {:ok, flow_node_instance} ->
        {:ok, flow_node_instance}

      {:error, :not_found} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(interval)
          do_poll_waiting_flow_node_instance(process_instance_id, flow_node_type, interval, deadline)
        end
    end
  end
end
