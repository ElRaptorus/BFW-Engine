defmodule EvilEngine.ExecutionCase do
  @moduledoc """
  Case template for execution integration tests.

  Extends `IntegrationCase` with Ecto Sandbox checkout, persistence
  adapter wiring, and event collector setup so tests can verify
  DB state and event ordering against real BPMN files.

  Provides two approaches for starting processes:

  - `start_process/2` — direct call to `Execution.start_process_instance/1`,
    bypassing HTTP. Use only for per-app unit tests in `core_execution`.
  - `http_deploy/2` + `http_start/3` — full HTTP round-trip through
    `POST /processes` and `POST /processes/{model_id}/start`. Use for all
    umbrella-level integration tests.
  """

  use ExUnit.CaseTemplate

  @test_secret "test_only_secret_at_least_32_bytes!"
  @fixtures_dir Path.expand("../fixtures/bpmns", __DIR__)
  @dmn_fixtures_dir Path.expand("../fixtures/dmns", __DIR__)

  using do
    quote do
      import Plug.Test
      import Plug.Conn
      import EvilEngine.ExecutionCase
      import EvilEngine.Test.DbAssertions
      import EvilEngine.Test.EventCollector
      import EvilEngine.Test.BpmnLoader
      import EvilEngine.Test.ProcessInteractions
    end
  end

  setup do
    EvilEngine.Events.EngineEventBus.reset_state()
    EvilEngine.Events.MessageSubscriptions.reset_state()
    EvilEngine.Events.MessageSubscriptions.mark_ready()
    EvilEngine.Events.SignalSubscriptions.reset_state()
    EvilEngine.Events.SignalSubscriptions.mark_ready()
    EvilEngine.Plugins.Registry.reset_state()
    EvilEngine.Auth.ProviderRegistry.reset_to_default()
    EvilEngine.BPMN.ModelCache.reset_state()
    terminate_all_process_instances()
    ensure_test_secret()

    Application.put_env(
      :core_execution,
      :persistence_adapter,
      EvilEngine.Persistence.ExecutionAdapter
    )

    Application.put_env(
      :core_execution,
      :called_element_resolver,
      EvilEngine.Persistence.CalledElementResolverImpl
    )

    Application.put_env(
      :core_execution,
      :decision_resolver,
      EvilEngine.Persistence.DecisionResolverImpl
    )

    Ecto.Adapters.SQL.Sandbox.checkout(EvilEngine.Persistence.Repo,
      ownership_timeout: 300_000
    )
    Ecto.Adapters.SQL.Sandbox.mode(EvilEngine.Persistence.Repo, {:shared, self()})

    Ecto.Adapters.SQL.Sandbox.checkout(EvilEngine.Persistence.ReadRepo,
      ownership_timeout: 300_000
    )
    Ecto.Adapters.SQL.Sandbox.mode(EvilEngine.Persistence.ReadRepo, {:shared, self()})

    {:ok, collector_pid} = EvilEngine.Test.EventCollector.start_link(self())

    on_exit(fn ->
      terminate_all_process_instances()
      Process.sleep(50)

      Application.delete_env(:core_execution, :persistence_adapter)
      Application.delete_env(:core_execution, :called_element_resolver)
      Application.delete_env(:core_execution, :decision_resolver)

      if Process.alive?(collector_pid) do
        try do
          GenServer.stop(collector_pid)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    {:ok, collector: collector_pid}
  end

  defp terminate_all_process_instances do
    children = DynamicSupervisor.which_children(EvilEngine.Execution.Supervisor)

    Enum.each(children, fn {_, pid, _, _} ->
      DynamicSupervisor.terminate_child(EvilEngine.Execution.Supervisor, pid)
    end)
  rescue
    _ -> :ok
  end

  defp ensure_test_secret do
    case Application.get_env(:api_auth, :hs256_secret) do
      nil -> Application.put_env(:api_auth, :hs256_secret, @test_secret)
      _ -> :ok
    end
  end

  @doc """
  Start a process instance directly (bypasses HTTP layer).

  Use only for per-app unit tests in `core_execution` that
  intentionally test the runtime in isolation.
  """
  def start_process(process_version_id, opts \\ []) do
    process_instance_id = opts[:process_instance_id] || Ash.UUIDv7.generate()

    process_instance_options = %{
      process_instance_id: process_instance_id,
      process_version_id: process_version_id,
      start_event_id: opts[:start_event_id],
      payload: opts[:payload] || %{},
      identity: opts[:identity] || %EvilEngine.Types.Identity{id: "test-user", roles: ["admin"], groups: []}
    }

    case EvilEngine.Execution.start_process_instance(process_instance_options) do
      {:ok, pid} -> {:ok, pid, process_instance_id}
      error -> error
    end
  end

  @doc "Generate a fresh UUIDv7 for use as a process version ID."
  def gen_version_id, do: Ash.UUIDv7.generate()

  # ---------------------------------------------------------------------------
  # HTTP round-trip helpers
  # ---------------------------------------------------------------------------

  @doc """
  Deploy a BPMN fixture file via `POST /processes` (authenticated HTTP).

  Automatically includes `deploy_bpmn: true` unless overridden.
  Returns `{status, body}`.
  """
  def http_deploy(fixture_name, claims \\ %{}) do
    merged = Map.merge(%{"deploy_bpmn" => true}, claims)
    xml = File.read!(Path.join(@fixtures_dir, fixture_name))
    body = Jason.encode!(%{"sources" => [xml]})

    conn =
      Plug.Test.conn(:post, "/processes", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(merged)}")
      |> route()

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  @doc """
  Deploy raw BPMN XML via `POST /processes` (authenticated HTTP).

  Automatically includes `deploy_bpmn: true` unless overridden.
  Returns `{status, body}`.
  """
  def http_deploy_xml(xml, claims \\ %{}) do
    merged = Map.merge(%{"deploy_bpmn" => true}, claims)
    body = Jason.encode!(%{"sources" => [xml]})

    conn =
      Plug.Test.conn(:post, "/processes", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(merged)}")
      |> route()

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  @doc """
  Start a process instance via `POST /processes/{model_id}/start` (authenticated HTTP).

  Returns `{status, body}`.
  """
  def http_start(process_model_id, body \\ %{}, claims \\ %{}) do
    json_body = Jason.encode!(body)

    conn =
      Plug.Test.conn(:post, "/processes/#{process_model_id}/start", json_body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(claims)}")
      |> route()

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  @doc """
  Deploy a fixture and start it via HTTP. Returns the PI ID on success.

  Raises on deployment or start failure.
  """
  def http_deploy_and_start(fixture_name, process_model_id, start_body \\ %{}) do
    {201, _} = http_deploy(fixture_name)
    {201, body} = http_start(process_model_id, start_body)
    body["processInstanceId"]
  end

  @doc """
  Finish a waiting User Task via `PUT /user-tasks/{fniId}/finish` (authenticated HTTP).

  Returns `{status, body}`.
  """
  def http_finish_user_task(flow_node_instance_id, result \\ %{}, claims \\ %{}) do
    json_body = Jason.encode!(%{"result" => result})

    conn =
      Plug.Test.conn(:put, "/user-tasks/#{flow_node_instance_id}/finish", json_body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(claims)}")
      |> route()

    decode_response(conn)
  end

  @doc """
  Cancel a waiting User Task via `PUT /user-tasks/{fniId}/cancel` (authenticated HTTP).

  Returns `{status, body}`.
  """
  def http_cancel_user_task(flow_node_instance_id, reason \\ nil, claims \\ %{}) do
    body = if reason, do: %{"reason" => reason}, else: %{}
    json_body = Jason.encode!(body)

    conn =
      Plug.Test.conn(:put, "/user-tasks/#{flow_node_instance_id}/cancel", json_body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(claims)}")
      |> route()

    decode_response(conn)
  end

  @doc """
  Abort a process instance via `PUT /process-instances/{id}/abort` (authenticated HTTP).

  Returns `{status, body}`.
  """
  def http_abort_process_instance(process_instance_id, reason \\ nil, claims \\ %{}) do
    body = if reason, do: %{"reason" => reason}, else: %{}
    json_body = Jason.encode!(body)

    conn =
      Plug.Test.conn(:put, "/process-instances/#{process_instance_id}/abort", json_body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(claims)}")
      |> route()

    decode_response(conn)
  end

  @doc """
  Retry a process instance via `PUT /process-instances/{id}/retry` (authenticated HTTP).

  Automatically includes `retry_process_instance: "all"` unless overridden.
  Returns `{status, body}`.
  """
  def http_retry_process_instance(process_instance_id, body \\ %{}, claims \\ %{}) do
    merged = Map.merge(%{"retry_process_instance" => "all"}, claims)
    json_body = Jason.encode!(body)

    conn =
      Plug.Test.conn(:put, "/process-instances/#{process_instance_id}/retry", json_body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(merged)}")
      |> route()

    decode_response(conn)
  end

  @doc """
  Trigger a named message via `POST /messages/{message_name}/trigger` (authenticated HTTP).

  Automatically includes `trigger_message: "all"` unless overridden.
  Returns `{status, body}`.
  """
  def http_trigger_message(message_name, payload \\ %{}, correlation \\ nil, claims \\ %{}) do
    merged = Map.merge(%{"trigger_message" => "all"}, claims)
    body = %{"payload" => payload}
    body = if correlation, do: Map.put(body, "correlation", correlation), else: body
    json_body = Jason.encode!(body)

    conn =
      Plug.Test.conn(:post, "/messages/#{URI.encode_www_form(message_name)}/trigger", json_body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(merged)}")
      |> route()

    decode_response(conn)
  end

  @doc """
  Trigger a named signal via `POST /signals/{signal_name}/trigger` (authenticated HTTP).

  Signals carry no payload and no correlation. Any body content is silently
  ignored by the engine. Automatically includes `trigger_signal: "all"` unless
  overridden. Returns `{status, body}`.
  """
  def http_trigger_signal(signal_name, claims \\ %{}) do
    merged = Map.merge(%{"trigger_signal" => "all"}, claims)
    json_body = Jason.encode!(%{})

    conn =
      Plug.Test.conn(:post, "/signals/#{URI.encode_www_form(signal_name)}/trigger", json_body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(merged)}")
      |> route()

    decode_response(conn)
  end

  @doc """
  Trigger a timer event via `POST /timer-events/{fniId}/trigger` (authenticated HTTP).

  Returns `{status, body}`.
  """
  def http_trigger_timer_event(flow_node_instance_id, claims \\ %{}) do
    json_body = Jason.encode!(%{})

    conn =
      Plug.Test.conn(:post, "/timer-events/#{flow_node_instance_id}/trigger", json_body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(claims)}")
      |> route()

    decode_response(conn)
  end

  @doc """
  Delete a process instance via `DELETE /process-instances/{id}` (authenticated HTTP).

  Automatically includes `delete_process_instance: "all"` unless overridden.
  Returns `{status, body}`.
  """
  def http_delete_process_instance(process_instance_id, claims \\ %{}) do
    merged = Map.merge(%{"delete_process_instance" => "all"}, claims)

    conn =
      Plug.Test.conn(:delete, "/process-instances/#{process_instance_id}", "")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(merged)}")
      |> route()

    decode_response(conn)
  end

  @doc """
  Enable a process via `PUT /processes/{model_id}/enable` (authenticated HTTP).

  Automatically includes `deploy_bpmn: true` unless overridden.
  Returns `{status, body}`.
  """
  def http_enable(process_model_id, claims \\ %{}) do
    merged = Map.merge(%{"deploy_bpmn" => true}, claims)

    conn =
      Plug.Test.conn(:put, "/processes/#{process_model_id}/enable", "")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(merged)}")
      |> route()

    decode_response(conn)
  end

  @doc """
  Disable a process via `PUT /processes/{model_id}/disable` (authenticated HTTP).

  Automatically includes `deploy_bpmn: true` unless overridden.
  Returns `{status, body}`.
  """
  def http_disable(process_model_id, claims \\ %{}) do
    merged = Map.merge(%{"deploy_bpmn" => true}, claims)

    conn =
      Plug.Test.conn(:put, "/processes/#{process_model_id}/disable", "")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(merged)}")
      |> route()

    decode_response(conn)
  end

  @doc """
  Show a process via `GET /processes/{model_id}` (authenticated HTTP).

  Supports `?includeXml=true` via the `query_params` option.
  Returns `{status, body}`.
  """
  def http_show_process(process_model_id, opts \\ []) do
    claims = Keyword.get(opts, :claims, %{})
    query = if Keyword.get(opts, :include_xml, false), do: "?includeXml=true", else: ""

    conn =
      Plug.Test.conn(:get, "/processes/#{process_model_id}#{query}")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(claims)}")
      |> route()

    decode_response(conn)
  end

  @doc """
  List versions via `GET /processes/{model_id}/versions` (authenticated HTTP).

  Supports `?includeXml=true` via the `include_xml` option.
  Returns `{status, body}`.
  """
  def http_list_versions(process_model_id, opts \\ []) do
    claims = Keyword.get(opts, :claims, %{})
    query = if Keyword.get(opts, :include_xml, false), do: "?includeXml=true", else: ""

    conn =
      Plug.Test.conn(:get, "/processes/#{process_model_id}/versions#{query}")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(claims)}")
      |> route()

    decode_response(conn)
  end

  @doc """
  List all deployed processes via `GET /processes` (authenticated HTTP).

  Returns `{status, body}`.
  """
  def http_list_processes(claims \\ %{}) do
    conn =
      Plug.Test.conn(:get, "/processes")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(claims)}")
      |> route()

    decode_response(conn)
  end

  @doc """
  Undeploy a process (delete all versions) via `DELETE /processes/{model_id}` (authenticated HTTP).

  Automatically includes `delete_bpmn: true` unless overridden.
  Returns `{status, body}`.
  """
  def http_undeploy_process(process_model_id, claims \\ %{}) do
    merged = Map.merge(%{"delete_bpmn" => true}, claims)

    conn =
      Plug.Test.conn(:delete, "/processes/#{process_model_id}", "")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(merged)}")
      |> route()

    decode_response(conn)
  end

  @doc """
  Delete a process version via `DELETE /processes/{model_id}/versions/{version}` (authenticated HTTP).

  Automatically includes `delete_bpmn: true` unless overridden.
  Returns `{status, body}`.
  """
  def http_delete_version(process_model_id, version, claims \\ %{}) do
    merged = Map.merge(%{"delete_bpmn" => true}, claims)

    conn =
      Plug.Test.conn(:delete, "/processes/#{process_model_id}/versions/#{version}", "")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(merged)}")
      |> route()

    decode_response(conn)
  end

  @doc """
  Execute a GraphQL query via `POST /api/v1/graphql` (authenticated HTTP).

  Returns `{status, body}`.
  """
  def http_graphql(query, variables \\ %{}, claims \\ %{}) do
    json_body = Jason.encode!(%{"query" => query, "variables" => variables})

    conn =
      Plug.Test.conn(:post, "/api/v1/graphql", json_body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(claims)}")
      |> route()

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  @doc """
  Poll until a PI appears in the Execution Registry (i.e., it's alive).

  Returns `{:ok, pid}` once found, or raises on timeout.
  Use after `ResumeRunner.resume_all/0` or any operation that starts a PI
  asynchronously instead of a fixed `Process.sleep`.
  """
  def poll_pi_alive(process_instance_id, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_poll_pi_alive(process_instance_id, deadline)
  end

  defp do_poll_pi_alive(process_instance_id, deadline) do
    case EvilEngine.Execution.lookup_process_instance(process_instance_id) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, :not_found} ->
        if System.monotonic_time(:millisecond) >= deadline do
          raise "PI #{process_instance_id} did not appear in Registry within timeout"
        else
          Process.sleep(25)
          do_poll_pi_alive(process_instance_id, deadline)
        end
    end
  end

  @doc """
  Poll until an FNI of the given type reaches the expected state in persistence.

  Returns the matching FNI record, or raises on timeout.
  Use instead of `Process.sleep` + `fetch_flow_node_instances` + `Enum.find`.
  """
  def poll_fni_state(process_instance_id, flow_node_type, expected_state, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_poll_fni_state(process_instance_id, flow_node_type, expected_state, deadline)
  end

  defp do_poll_fni_state(process_instance_id, flow_node_type, expected_state, deadline) do
    flow_node_instances = EvilEngine.Test.DbAssertions.fetch_flow_node_instances(process_instance_id)

    match =
      Enum.find(flow_node_instances, fn flow_node_instance ->
        flow_node_instance.flow_node_type == flow_node_type and
          flow_node_instance.state == expected_state
      end)

    case match do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          states =
            flow_node_instances
            |> Enum.filter(&(&1.flow_node_type == flow_node_type))
            |> Enum.map(& &1.state)

          raise "FNI #{flow_node_type} never reached #{expected_state} " <>
                  "within timeout (current states: #{inspect(states)})"
        else
          Process.sleep(25)
          do_poll_fni_state(process_instance_id, flow_node_type, expected_state, deadline)
        end

      flow_node_instance ->
        flow_node_instance
    end
  end

  @doc """
  Poll until a PI reaches the expected state in persistence.

  Returns the PI record. Retries on transient DB connection errors
  (e.g. sandbox ownership race conditions after fast-completing PIs).
  """
  def poll_pi_state(process_instance_id, expected_state, timeout \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_poll_pi_state(process_instance_id, expected_state, deadline)
  end

  defp do_poll_pi_state(process_instance_id, expected_state, deadline) do
    result =
      try do
        EvilEngine.Test.DbAssertions.fetch_process_instance(process_instance_id)
      rescue
        _ -> :db_error
      end

    case result do
      %{state: ^expected_state} = record ->
        record

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          current_state = if is_map(result), do: result.state, else: "unavailable"

          raise "PI #{process_instance_id} never reached #{expected_state} " <>
                  "within timeout (current state: #{current_state})"
        else
          Process.sleep(50)
          do_poll_pi_state(process_instance_id, expected_state, deadline)
        end
    end
  end

  @doc """
  Wait for a PI to stop by looking up its PID from the Execution Registry.

  Handles the race where the PI already terminated before lookup.
  """
  def wait_for_process_instance(process_instance_id, timeout \\ 2_000) do
    case EvilEngine.Execution.lookup_process_instance(process_instance_id) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          timeout ->
            Process.demonitor(ref, [:flush])
            raise "PI #{process_instance_id} did not stop within #{timeout}ms"
        end

      {:error, :not_found} ->
        :ok
    end
  end

  @doc "Fetch a single DataObject snapshot by PI + data_object_id."
  def fetch_data_object(process_instance_id, data_object_id) do
    require Ash.Query
    alias EvilEngine.Persistence.Resources.DataObject, as: DataObjectResource

    case DataObjectResource
         |> Ash.Query.filter(process_instance_id == ^process_instance_id and data_object_id == ^data_object_id)
         |> Ash.read(domain: EvilEngine.Persistence.Api, authorize?: false) do
      {:ok, [record]} -> record
      {:ok, []} -> nil
      _ -> nil
    end
  end

  @doc "Fetch all DataObject snapshots for a PI."
  def fetch_data_objects(process_instance_id) do
    require Ash.Query
    alias EvilEngine.Persistence.Resources.DataObject, as: DataObjectResource

    case DataObjectResource
         |> Ash.Query.filter(process_instance_id == ^process_instance_id)
         |> Ash.read(domain: EvilEngine.Persistence.Api, authorize?: false) do
      {:ok, records} -> records
      _ -> []
    end
  end

  @doc "Fetch DataObjectWrite audit rows, optionally filtered by data_object_id."
  def fetch_data_object_writes(process_instance_id, data_object_id \\ nil) do
    require Ash.Query
    alias EvilEngine.Persistence.Resources.DataObjectWrite, as: WriteResource

    query =
      WriteResource
      |> Ash.Query.filter(process_instance_id == ^process_instance_id)
      |> Ash.Query.sort(created_at: :asc)

    query =
      if data_object_id do
        Ash.Query.filter(query, data_object_id == ^data_object_id)
      else
        query
      end

    case Ash.read(query, domain: EvilEngine.Persistence.Api, authorize?: false) do
      {:ok, records} -> records
      _ -> []
    end
  end

  @doc """
  Deploy a DMN fixture file via `POST /decisions` (authenticated HTTP).

  Automatically includes `deploy_dmn: true` unless overridden.
  Returns `{status, body}`.
  """
  def http_deploy_dmn(fixture_name, claims \\ %{}) do
    merged = Map.merge(%{"deploy_dmn" => true}, claims)
    xml = File.read!(Path.join(@dmn_fixtures_dir, fixture_name))
    body = Jason.encode!(%{"sources" => [xml]})

    conn =
      Plug.Test.conn(:post, "/decisions", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(merged)}")
      |> route()

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  @doc """
  Deploy raw DMN XML via `POST /decisions` (authenticated HTTP).

  Returns `{status, body}`.
  """
  def http_deploy_dmn_xml(xml, claims \\ %{}) do
    merged = Map.merge(%{"deploy_dmn" => true}, claims)
    body = Jason.encode!(%{"sources" => [xml]})

    conn =
      Plug.Test.conn(:post, "/decisions", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(merged)}")
      |> route()

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  @doc """
  Deploy via `POST /decisions` with an arbitrary JSON body (authenticated HTTP).

  Returns `{status, body}`.
  """
  def http_deploy_dmn_raw(request_body, claims \\ %{}) do
    merged = Map.merge(%{"deploy_dmn" => true}, claims)
    json_body = Jason.encode!(request_body)

    conn =
      Plug.Test.conn(:post, "/decisions", json_body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(merged)}")
      |> route()

    case conn.resp_body do
      "" -> {conn.status, nil}
      response_body -> {conn.status, Jason.decode!(response_body)}
    end
  end

  @doc """
  Evaluate a decision via `POST /decisions/{model_id}/evaluate` (authenticated HTTP).

  Returns `{status, body}`.
  """
  def http_evaluate_decision(decision_definition_id, input \\ %{}, opts \\ []) do
    claims = Keyword.get(opts, :claims, %{})
    decision_model_id = Keyword.get(opts, :decision_model_id)
    include_unmatched = Keyword.get(opts, :include_unmatched_details, false)

    request_body = %{"input" => input}
    request_body = if decision_model_id, do: Map.put(request_body, "decisionModelId", decision_model_id), else: request_body
    request_body = if include_unmatched, do: Map.put(request_body, "includeUnmatchedDetails", true), else: request_body

    json_body = Jason.encode!(request_body)

    conn =
      Plug.Test.conn(:post, "/decisions/#{decision_definition_id}/evaluate", json_body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(claims)}")
      |> route()

    case conn.resp_body do
      "" -> {conn.status, nil}
      response_body -> {conn.status, Jason.decode!(response_body)}
    end
  end

  @doc """
  Evaluate a Decision Service via `POST /decisions/{model_id}/services/{service_id}/evaluate` (authenticated HTTP).

  Returns `{status, body}`.
  """
  def http_evaluate_decision_service(decision_definition_id, service_id, input \\ %{}, opts \\ []) do
    claims = Keyword.get(opts, :claims, %{})
    request_body = %{"input" => input}
    json_body = Jason.encode!(request_body)

    conn =
      Plug.Test.conn(
        :post,
        "/decisions/#{decision_definition_id}/services/#{service_id}/evaluate",
        json_body
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(claims)}")
      |> route()

    case conn.resp_body do
      "" -> {conn.status, nil}
      response_body -> {conn.status, Jason.decode!(response_body)}
    end
  end

  @doc """
  Evaluate a decision by a specific version via
  `POST /decisions/{model_id}/versions/{version}/evaluate` (authenticated HTTP).

  Returns `{status, body}`.
  """
  def http_evaluate_decision_by_version(decision_definition_id, version, input \\ %{}, opts \\ []) do
    claims = Keyword.get(opts, :claims, %{})
    decision_model_id = Keyword.get(opts, :decision_model_id)
    include_unmatched = Keyword.get(opts, :include_unmatched_details, false)

    request_body = %{"input" => input}

    request_body =
      if decision_model_id, do: Map.put(request_body, "decisionModelId", decision_model_id), else: request_body

    request_body =
      if include_unmatched, do: Map.put(request_body, "includeUnmatchedDetails", true), else: request_body

    json_body = Jason.encode!(request_body)

    conn =
      Plug.Test.conn(
        :post,
        "/decisions/#{decision_definition_id}/versions/#{version}/evaluate",
        json_body
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(claims)}")
      |> route()

    decode_response(conn)
  end

  @doc """
  List all decisions via `GET /decisions` (authenticated HTTP).

  Returns `{status, body}`.
  """
  def http_list_decisions(claims \\ %{}) do
    conn =
      Plug.Test.conn(:get, "/decisions")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(claims)}")
      |> route()

    decode_response(conn)
  end

  @doc """
  Show a decision via `GET /decisions/{model_id}` (authenticated HTTP).

  Returns `{status, body}`.
  """
  def http_show_decision(decision_definition_id, opts \\ []) do
    claims = Keyword.get(opts, :claims, %{})
    query = if Keyword.get(opts, :include_xml, false), do: "?includeXml=true", else: ""

    conn =
      Plug.Test.conn(:get, "/decisions/#{decision_definition_id}#{query}")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(claims)}")
      |> route()

    decode_response(conn)
  end

  @doc """
  List versions via `GET /decisions/{model_id}/versions` (authenticated HTTP).

  Returns `{status, body}`.
  """
  def http_list_decision_versions(decision_definition_id, opts \\ []) do
    claims = Keyword.get(opts, :claims, %{})
    query = if Keyword.get(opts, :include_xml, false), do: "?includeXml=true", else: ""

    conn =
      Plug.Test.conn(:get, "/decisions/#{decision_definition_id}/versions#{query}")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(claims)}")
      |> route()

    decode_response(conn)
  end

  @doc """
  Enable a decision via `PUT /decisions/{model_id}/enable` (authenticated HTTP).

  Returns `{status, body}`.
  """
  def http_enable_decision(decision_definition_id, claims \\ %{}) do
    merged = Map.merge(%{"deploy_dmn" => true}, claims)

    conn =
      Plug.Test.conn(:put, "/decisions/#{decision_definition_id}/enable", "")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(merged)}")
      |> route()

    decode_response(conn)
  end

  @doc """
  Disable a decision via `PUT /decisions/{model_id}/disable` (authenticated HTTP).

  Returns `{status, body}`.
  """
  def http_disable_decision(decision_definition_id, claims \\ %{}) do
    merged = Map.merge(%{"deploy_dmn" => true}, claims)

    conn =
      Plug.Test.conn(:put, "/decisions/#{decision_definition_id}/disable", "")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(merged)}")
      |> route()

    decode_response(conn)
  end

  @doc """
  Undeploy a decision via `DELETE /decisions/{model_id}` (authenticated HTTP).

  Returns `{status, body}`.
  """
  def http_undeploy_decision(decision_definition_id, claims \\ %{}) do
    merged = Map.merge(%{"delete_dmn" => true}, claims)

    conn =
      Plug.Test.conn(:delete, "/decisions/#{decision_definition_id}", "")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(merged)}")
      |> route()

    decode_response(conn)
  end

  @doc """
  Delete a decision version via `DELETE /decisions/{model_id}/versions/{version}` (authenticated HTTP).

  Returns `{status, body}`.
  """
  def http_delete_decision_version(decision_definition_id, version, claims \\ %{}) do
    merged = Map.merge(%{"delete_dmn" => true}, claims)

    conn =
      Plug.Test.conn(:delete, "/decisions/#{decision_definition_id}/versions/#{version}", "")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(merged)}")
      |> route()

    decode_response(conn)
  end

  @doc "Sign a test JWT with HS256."
  def sign_jwt(claims \\ %{}) do
    secret = Application.get_env(:api_auth, :hs256_secret) || @test_secret
    jwk = JOSE.JWK.from_oct(secret)

    defaults = %{
      "sub" => "test-user",
      "exp" => DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_unix(),
      "iat" => DateTime.utc_now() |> DateTime.to_unix(),
      "lane:default" => true
    }

    merged = Map.merge(defaults, claims)
    {_, compact} = JOSE.JWT.sign(jwk, %{"alg" => "HS256"}, merged) |> JOSE.JWS.compact()
    compact
  end

  @doc "Send a conn through the full HTTP Endpoint (includes Plug.Parsers)."
  def route(conn) do
    EvilEngineWeb.Http.Endpoint.call(conn, EvilEngineWeb.Http.Endpoint.init([]))
  end

  @doc false
  def decode_response(conn) do
    case conn.resp_body do
      "" -> {conn.status, nil}
      body -> {conn.status, Jason.decode!(body)}
    end
  end
end
