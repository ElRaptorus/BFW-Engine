defmodule EvilEngineWeb.Http.ProcessController do
  @moduledoc """
  REST controller for BPMN process deployment, catalog operations,
  and process instance lifecycle.

  ## Routes

  - `GET /processes` — list all deployed processes
  - `GET /processes/:model_id` — show process metadata (optional `?includeXml=true`)
  - `GET /processes/:model_id/versions` — list version history (optional `?includeXml=true`)
  - `POST /processes` — deploy one or more BPMN definitions (atomic batch)
  - `POST /processes/:model_id/start` — start a new process instance
  - `PUT /processes/:model_id/enable` — enable a process (204)
  - `PUT /processes/:model_id/disable` — disable a process (204)
  - `DELETE /processes/:model_id` — undeploy a process (delete all versions)
  - `DELETE /processes/:model_id/versions/:version` — delete a version (204)
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  import EvilEngineWeb.Http.ErrorResponse

  alias EvilEngine.Api
  alias EvilEngine.Types.Wire

  # ---------------------------------------------------------------------------
  # POST /processes — atomic batch deploy
  # ---------------------------------------------------------------------------

  def deploy(conn, _params) do
    case extract_bpmn_entries(conn) do
      {:ok, bpmn_entries} ->
        bpmn_entries
        |> Api.deploy_bpmn(deployer_identity(conn), source: rest_source(conn))
        |> render_deploy_result(conn)

      {:error, :invalid_sources} ->
        render_error(
          conn,
          400,
          "bad_request",
          "Request body must contain a non-empty \"sources\" array of BPMN XML strings"
        )
    end
  end

  defp render_deploy_result({:ok, results}, conn) do
    conn |> put_status(201) |> json(Wire.camelize_keys(%{deployed: results}))
  end

  defp render_deploy_result({:error, :parse_error, failures}, conn) do
    render_error(conn, 400, "parse_error", "BPMN parsing failed", failures: failures)
  end

  defp render_deploy_result({:error, :validation_failed, failures}, conn) do
    render_error(conn, 422, "validation_failed", "BPMN validation failed", failures: failures)
  end

  defp render_deploy_result({:error, :linter_gate_failed, failures}, conn) do
    render_error(conn, 422, "linter_gate_failed", "Linter gate check failed", failures: failures)
  end

  defp render_deploy_result({:error, :version_exists, conflicts}, conn) do
    render_error(conn, 409, "version_exists", "One or more versions already exist",
      conflicts: conflicts
    )
  end

  defp render_deploy_result({:error, :batch_conflict, conflicts}, conn) do
    render_error(conn, 409, "batch_conflict", "Duplicate versions within the batch",
      conflicts: conflicts
    )
  end

  defp render_deploy_result({:error, :forbidden, details}, conn) do
    forbidden(conn, details[:required_claim] || "deploy_bpmn", details)
  end

  defp render_deploy_result({:error, reason}, conn) do
    render_error(conn, 500, "internal_error", format_internal_error(reason))
  end

  # ---------------------------------------------------------------------------
  # POST /processes/:model_id/start
  # ---------------------------------------------------------------------------

  def start(conn, %{"model_id" => model_id}) do
    body = conn.body_params || %{}
    start_event_id = body["startEventId"]
    payload = body["payload"] || %{}
    context = body["context"]
    business_key = body["businessKey"]

    case resolve_latest_version(model_id) do
      {:ok, _process, version} ->
        handle_start(conn, model_id, version, start_event_id, payload, context, business_key)

      :not_found ->
        render_error(conn, 404, "process_not_found", "Process not found")

      {:error, :process_disabled} ->
        render_error(conn, 422, "process_disabled", "Process is disabled")

      {:error, :no_active_version} ->
        render_error(conn, 404, "no_active_version", "No active (non-deleted) version available")
    end
  end

  defp handle_start(conn, model_id, version, start_event_id, payload, context, business_key) do
    case do_start(version, start_event_id, payload, context, business_key, conn) do
      {:ok, process_instance_id} ->
        conn
        |> put_status(201)
        |> json(
          Wire.camelize_keys(%{
            process_instance_id: process_instance_id,
            process_model_id: model_id,
            version: version.version,
            state: "running"
          })
        )

      start_error ->
        render_start_error(conn, start_error)
    end
  end

  defp render_start_error(conn, {:error, :ambiguous_start_event, message}) do
    render_error(conn, 422, "ambiguous_start_event", message)
  end

  defp render_start_error(conn, {:error, :start_event_not_found, message}) do
    render_error(conn, 422, "start_event_not_found", message)
  end

  defp render_start_error(conn, {:error, :no_start_event, message}) do
    render_error(conn, 422, "no_start_event", message)
  end

  defp render_start_error(conn, {:error, :no_executable_process}) do
    render_error(
      conn,
      422,
      "no_executable_process",
      "No executable process found in BPMN model"
    )
  end

  defp render_start_error(conn, {:error, :process_disabled}) do
    render_error(conn, 422, "process_disabled", "Process is disabled")
  end

  defp render_start_error(conn, {:error, :not_found}) do
    render_error(conn, 404, "not_found", "Process or start event not found")
  end

  defp render_start_error(conn, {:error, :engine_at_capacity, capacity_info}) do
    conn
    |> put_resp_header("retry-after", "5")
    |> render_error(503, "engine_at_capacity", "Maximum concurrent process instances reached",
      active: capacity_info.active,
      limit: engine_at_capacity_limit_json(capacity_info.limit),
      retry_after_seconds: 5
    )
  end

  defp render_start_error(conn, {:error, :payload_too_large, message}) do
    render_error(conn, 422, "payload_too_large", message)
  end

  defp render_start_error(conn, {:error, :no_matching_condition, message}) do
    render_error(conn, 422, "no_matching_condition", message)
  end

  defp render_start_error(conn, {:error, :start_failed_unknown}) do
    render_error(
      conn,
      500,
      "internal_error",
      "Process start failed — check server logs for details"
    )
  end

  defp render_start_error(conn, {:error, reason}) do
    Logger.error("Process start failed with unrecognized error: #{inspect(reason)}")

    render_error(
      conn,
      500,
      "internal_error",
      "Process start failed — check server logs for details"
    )
  end

  # ---------------------------------------------------------------------------
  # GET /processes
  # ---------------------------------------------------------------------------

  def index(conn, _params) do
    json(conn, Wire.camelize_keys(list_all_processes()))
  end

  # ---------------------------------------------------------------------------
  # GET /processes/:model_id
  # ---------------------------------------------------------------------------

  def show(conn, %{"model_id" => model_id}) do
    include_xml? = include_xml_param?(conn)

    case Api.get_process_by_model_id(model_id) do
      {:ok, process} ->
        json(conn, Wire.camelize_keys(build_process_detail(process, include_xml?)))

      :not_found ->
        render_error(conn, 404, "not_found", "Process not found")
    end
  end

  # ---------------------------------------------------------------------------
  # GET /processes/:model_id/versions
  # ---------------------------------------------------------------------------

  def versions(conn, %{"model_id" => model_id}) do
    include_xml? = include_xml_param?(conn)

    case Api.get_process_by_model_id(model_id) do
      {:ok, process} ->
        entries = build_version_list(process, include_xml?)
        json(conn, Wire.camelize_keys(entries))

      :not_found ->
        render_error(conn, 404, "not_found", "Process not found")
    end
  end

  # ---------------------------------------------------------------------------
  # PUT /processes/:model_id/enable
  # ---------------------------------------------------------------------------

  def enable(conn, %{"model_id" => model_id}) do
    toggle_enabled(conn, model_id, true)
  end

  # ---------------------------------------------------------------------------
  # PUT /processes/:model_id/disable
  # ---------------------------------------------------------------------------

  def disable(conn, %{"model_id" => model_id}) do
    toggle_enabled(conn, model_id, false)
  end

  # ---------------------------------------------------------------------------
  # DELETE /processes/:model_id/versions/:version
  # ---------------------------------------------------------------------------

  def delete_version(conn, %{"model_id" => model_id, "version" => version}) do
    case Api.delete_process_version(model_id, version, caller_identity(conn),
           source: rest_source(conn)
         ) do
      {:ok, _updated} ->
        send_resp(conn, 204, "")

      {:error, :not_found} ->
        render_error(conn, 404, "not_found", "Version not found")

      {:error, :active_instances_exist} ->
        render_error(
          conn,
          409,
          "active_instances_exist",
          "Cannot delete version while non-terminal process instances are running on it"
        )

      {:error, :forbidden, details} ->
        forbidden(conn, details[:required_claim] || "delete_bpmn", details)

      {:error, reason} ->
        render_error(conn, 500, "internal_error", format_internal_error(reason))
    end
  end

  # ---------------------------------------------------------------------------
  # DELETE /processes/:model_id — undeploy (delete all versions)
  # ---------------------------------------------------------------------------

  def undeploy(conn, %{"model_id" => model_id}) do
    case Api.undeploy_process(model_id, caller_identity(conn), source: rest_source(conn)) do
      :ok ->
        send_resp(conn, 204, "")

      {:error, :not_found} ->
        render_error(conn, 404, "not_found", "Process not found")

      {:error, :no_active_versions} ->
        render_error(conn, 404, "not_found", "No active versions to undeploy")

      {:error, :active_instances_exist} ->
        render_error(
          conn,
          409,
          "active_instances_exist",
          "Cannot delete version while non-terminal process instances are running on it"
        )

      {:error, :forbidden, details} ->
        forbidden(conn, details[:required_claim] || "delete_bpmn", details)
    end
  end

  # ===========================================================================
  # Private helpers
  # ===========================================================================

  defp extract_bpmn_entries(conn) do
    with %{"sources" => sources} <- conn.body_params,
         true <- is_list(sources) and sources != [],
         true <- Enum.all?(sources, &is_binary/1) do
      entries =
        sources
        |> Enum.with_index(1)
        |> Enum.map(fn {xml, index} ->
          %{filename: "source_#{index}.bpmn", xml: xml}
        end)

      {:ok, entries}
    else
      _ -> {:error, :invalid_sources}
    end
  end

  defp format_internal_error(%{__exception__: true} = exception) do
    Logger.error("Deploy internal error: #{Exception.message(exception)}")
    "An internal error occurred during deployment. Server logs contain the technical details."
  end

  defp format_internal_error(reason) when is_binary(reason), do: reason

  defp format_internal_error(reason) do
    Logger.error("Deploy internal error: #{inspect(reason)}")
    "An internal error occurred during deployment. Server logs contain the technical details."
  end

  defp include_xml_param?(conn) do
    conn = Plug.Conn.fetch_query_params(conn)
    conn.query_params["includeXml"] == "true"
  end

  defp list_all_processes do
    case Api.list_processes() do
      {:ok, []} -> []
      {:ok, processes} -> build_process_listing(processes)
      _ -> []
    end
  end

  defp build_process_listing(processes) do
    process_ids = Enum.map(processes, & &1.id)
    latest_by_process = Api.find_latest_versions_by_process_ids(process_ids)
    Enum.flat_map(processes, &to_process_listing_entry(&1, latest_by_process))
  end

  defp to_process_listing_entry(process, latest_by_process) do
    case Map.get(latest_by_process, process.id) do
      nil ->
        []

      version ->
        [
          %{
            id: process.process_model_id,
            version_id: version.id,
            definitions_id: version.definitions_id,
            version: version.version,
            name: process.name,
            enabled: process.enabled,
            deployed_at: version.deployed_at
          }
        ]
    end
  end

  defp build_process_detail(process, include_xml?) do
    case Api.get_latest_process_version(process.id) do
      {:ok, version} ->
        base = %{
          id: process.process_model_id,
          version_id: version.id,
          definitions_id: version.definitions_id,
          version: version.version,
          name: process.name,
          enabled: process.enabled,
          deployed_at: version.deployed_at,
          deployer: version.deployer
        }

        if include_xml?, do: Map.put(base, :bpmn_xml, version.bpmn_xml), else: base

      _ ->
        %{
          id: process.process_model_id,
          name: process.name,
          enabled: process.enabled
        }
    end
  end

  defp build_version_list(process, include_xml?) do
    process.id
    |> Api.list_process_versions_for_process()
    |> Enum.map(&format_version_entry(&1, process, include_xml?))
  end

  defp format_version_entry(version, process, include_xml?) do
    entry = %{
      id: process.process_model_id,
      version_id: version.id,
      definitions_id: version.definitions_id,
      version: version.version,
      name: process.name,
      enabled: process.enabled,
      deployed_at: version.deployed_at,
      deployer: version.deployer
    }

    if include_xml?, do: Map.put(entry, :bpmn_xml, version.bpmn_xml), else: entry
  end

  defp toggle_enabled(conn, model_id, enabled_value) do
    case Api.get_process_by_model_id(model_id) do
      {:ok, process} ->
        case Api.update_process_enabled(process, enabled_value,
               source: rest_source(conn),
               identity: caller_identity(conn)
             ) do
          {:ok, _updated} ->
            send_resp(conn, 204, "")

          {:error, :forbidden, details} ->
            forbidden(conn, details[:required_claim] || "deploy_bpmn", details)

          {:error, reason} ->
            render_error(conn, 500, "internal_error", format_internal_error(reason))
        end

      :not_found ->
        render_error(conn, 404, "not_found", "Process not found")
    end
  end

  # ---------------------------------------------------------------------------
  # Start helpers
  # ---------------------------------------------------------------------------

  defp resolve_latest_version(model_id) do
    with {:ok, process} <- Api.get_process_by_model_id(model_id),
         :ok <- check_enabled(process),
         {:ok, version} <- Api.get_latest_process_version(process.id) do
      {:ok, process, version}
    end
  end

  defp check_enabled(%{enabled: true}), do: :ok
  defp check_enabled(_), do: {:error, :process_disabled}

  defp do_start(version, start_event_id, payload, context, business_key, conn) do
    process_instance_id = Ash.UUIDv7.generate()

    # Public start contract only. Internal execution options
    # (`parent_process_instance_id`, `triggerer_flow_node_instance_id`,
    # `subprocess_node_id`, ...) are intentionally omitted rather than pinned to
    # nil: `ProcessInstance.init/1` reads them via Access and defaults absent keys
    # to nil, so a REST start can never target an inner subprocess scope.
    start_opts = %{
      process_instance_id: process_instance_id,
      process_version_id: version.id,
      start_event_id: start_event_id,
      payload: payload,
      context: context,
      identity: caller_identity(conn),
      business_key: business_key
    }

    start_opts
    |> Api.start_process_instance(caller_identity(conn))
    |> normalize_start_result(process_instance_id)
  end

  defp normalize_start_result({:ok, _pid}, process_instance_id),
    do: {:ok, process_instance_id}

  defp normalize_start_result({:error, :engine_at_capacity, capacity_info}, _id),
    do: {:error, :engine_at_capacity, capacity_info}

  defp normalize_start_result({:error, reason, message}, _id)
       when is_atom(reason) and is_binary(message),
       do: {:error, reason, message}

  defp normalize_start_result({:error, {:shutdown, shutdown_reason}}, _id),
    do: normalize_start_supervisor_error(shutdown_reason)

  defp normalize_start_result({:error, {{reason, message}, _data}}, _id)
       when is_atom(reason) and is_binary(message),
       do: {:error, reason, message}

  defp normalize_start_result({:error, {reason, _data}}, _id) when is_atom(reason),
    do: {:error, reason}

  defp normalize_start_result({:error, reason}, _id),
    do: {:error, reason}

  defp normalize_start_supervisor_error({{reason, message}, _state})
       when is_atom(reason) and is_binary(message) do
    {:error, reason, message}
  end

  defp normalize_start_supervisor_error({:payload_too_large, details}) do
    {:error, :payload_too_large, payload_too_large_message(details)}
  end

  defp normalize_start_supervisor_error({:persistence_failed, reason}) do
    Logger.error("Process start persistence failed: #{inspect(reason)}")
    {:error, :start_failed_unknown}
  end

  defp normalize_start_supervisor_error({reason, _state}) when is_atom(reason) do
    {:error, reason, default_start_error_message(reason)}
  end

  defp normalize_start_supervisor_error(other) do
    Logger.error("Process start failed with unrecognized shutdown reason: #{inspect(other)}")
    {:error, :start_failed_unknown}
  end

  defp default_start_error_message(:no_executable_process),
    do: "No executable process found in BPMN model"

  defp default_start_error_message(:no_start_event), do: "No untyped Start Event found"

  defp default_start_error_message(reason) when is_atom(reason) do
    reason |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp payload_too_large_message(%{field: field, size: size, limit: limit}) do
    "#{field} size (#{size} bytes) exceeds limit (#{limit} bytes)"
  end

  defp payload_too_large_message(_details),
    do: "Start payload or context exceeds the configured size limit"

  defp caller_identity(conn) do
    case conn.assigns[:identity] do
      nil -> %EvilEngine.Types.Identity{id: "anonymous", roles: [], groups: []}
      identity -> identity
    end
  end

  defp deployer_identity(conn) do
    case conn.assigns[:identity] do
      nil -> %{type: "anonymous"}
      identity -> Map.from_struct(identity)
    end
  end

  defp rest_source(conn) do
    identity = caller_identity(conn)
    "user:#{identity.id}"
  end

  defp forbidden(conn, claim_name, details) do
    render_error(conn, 403, "forbidden", "Insufficient permissions",
      required_claim: claim_name,
      required_value: details[:required_value] || "true",
      resource: "process"
    )
  end

  defp engine_at_capacity_limit_json(:infinity), do: nil
  defp engine_at_capacity_limit_json(limit) when is_integer(limit), do: limit
end
