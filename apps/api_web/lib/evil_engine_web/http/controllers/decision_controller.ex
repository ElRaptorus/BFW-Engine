defmodule EvilEngineWeb.Http.DecisionController do
  @moduledoc """
  REST controller for DMN decision deployment, catalog operations,
  and ad-hoc evaluation.

  ## Routes

  - `GET /decisions` — list all deployed decisions
  - `GET /decisions/:model_id` — show decision metadata (optional `?includeXml=true`)
  - `GET /decisions/:model_id/versions` — list version history (optional `?includeXml=true`)
  - `POST /decisions` — deploy one or more DMN definitions (atomic batch)
  - `POST /decisions/:model_id/evaluate` — ad-hoc evaluation
  - `POST /decisions/:model_id/versions/:version/evaluate` — evaluate a specific version
  - `POST /decisions/:model_id/services/:service_id/evaluate` — evaluate a Decision Service
  - `PUT /decisions/:model_id/enable` — enable a decision (204)
  - `PUT /decisions/:model_id/disable` — disable a decision (204)
  - `DELETE /decisions/:model_id` — undeploy a decision (delete all versions)
  - `DELETE /decisions/:model_id/versions/:version` — delete a version (204)
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  import EvilEngineWeb.Http.ErrorResponse

  alias EvilEngine.Api
  alias EvilEngine.DMN.EvaluationResult
  alias EvilEngine.DMN.ServiceEvaluationResult
  alias EvilEngine.Types.Wire

  # ---------------------------------------------------------------------------
  # POST /decisions — atomic batch deploy
  # ---------------------------------------------------------------------------

  def deploy(conn, _params) do
    case extract_dmn_entries(conn) do
      {:ok, dmn_entries} ->
        dmn_entries
        |> Api.deploy_dmn(deployer_identity(conn), source: rest_source(conn))
        |> render_deploy_result(conn)

      {:error, :invalid_sources} ->
        render_error(
          conn,
          400,
          "bad_request",
          "Request body must contain a non-empty \"sources\" array of DMN XML strings"
        )
    end
  end

  defp render_deploy_result({:ok, results}, conn) do
    conn |> put_status(201) |> json(Wire.camelize_keys(%{deployed: results}))
  end

  defp render_deploy_result({:error, :dmn_parse_error, failures}, conn) do
    render_error(conn, 400, "dmn_parse_error", "DMN parsing failed", failures: failures)
  end

  defp render_deploy_result({:error, :validation_failed, failures}, conn) do
    render_error(conn, 422, "validation_failed", "DMN validation failed", failures: failures)
  end

  defp render_deploy_result({:error, :version_exists, conflicts}, conn) do
    render_error(conn, 409, "decision_version_exists", "One or more versions already exist",
      conflicts: conflicts
    )
  end

  defp render_deploy_result({:error, :forbidden, details}, conn) do
    forbidden(conn, details[:required_claim] || "deploy_dmn", details)
  end

  defp render_deploy_result({:error, _reason}, conn) do
    render_error(conn, 500, "internal_error", "Unexpected error during DMN deployment")
  end

  # ---------------------------------------------------------------------------
  # POST /decisions/:model_id/evaluate — ad-hoc DMN evaluation
  # ---------------------------------------------------------------------------

  def evaluate(conn, %{"model_id" => model_id}) do
    body = conn.body_params || %{}
    raw_input = body["input"] || %{}

    if is_map(raw_input) do
      do_evaluate(conn, model_id, raw_input, body)
    else
      render_error(conn, 400, "bad_request", "\"input\" must be a JSON object")
    end
  end

  defp do_evaluate(conn, model_id, input, body) do
    decision_model_id = body["decisionModelId"]
    include_unmatched = body["includeUnmatchedDetails"] == true

    case Api.evaluate_decision(model_id, input,
           decision_model_id: decision_model_id,
           include_unmatched_details: include_unmatched,
           source: rest_source(conn)
         ) do
      {:ok, result} ->
        json(conn, Wire.camelize_keys(EvaluationResult.to_json_map(result)))

      {:error, reason} ->
        handle_evaluate_error(conn, reason, decision_model_id)
    end
  end

  # ---------------------------------------------------------------------------
  # POST /decisions/:model_id/versions/:version/evaluate
  # ---------------------------------------------------------------------------

  def evaluate_version(conn, %{"model_id" => model_id, "version" => version}) do
    body = conn.body_params || %{}
    raw_input = body["input"] || %{}

    if is_map(raw_input) do
      do_evaluate_version(conn, model_id, version, raw_input, body)
    else
      render_error(conn, 400, "bad_request", "\"input\" must be a JSON object")
    end
  end

  defp do_evaluate_version(conn, model_id, version, input, body) do
    decision_model_id = body["decisionModelId"]
    include_unmatched = body["includeUnmatchedDetails"] == true

    case Api.evaluate_decision_by_version(model_id, version, input,
           decision_model_id: decision_model_id,
           include_unmatched_details: include_unmatched,
           source: rest_source(conn)
         ) do
      {:ok, result} ->
        json(conn, Wire.camelize_keys(EvaluationResult.to_json_map(result)))

      {:error, reason} ->
        handle_evaluate_error(conn, reason, decision_model_id)
    end
  end

  # ---------------------------------------------------------------------------
  # POST /decisions/:model_id/services/:service_id/evaluate
  # ---------------------------------------------------------------------------

  def evaluate_service(conn, %{"model_id" => model_id, "service_id" => service_id}) do
    body = conn.body_params || %{}
    raw_input = body["input"] || %{}

    if is_map(raw_input) do
      do_evaluate_service(conn, model_id, service_id, raw_input)
    else
      render_error(conn, 400, "bad_request", "\"input\" must be a JSON object")
    end
  end

  defp do_evaluate_service(conn, model_id, service_id, input) do
    case Api.evaluate_decision_service(model_id, service_id, input, source: rest_source(conn)) do
      {:ok, result} ->
        json(conn, Wire.camelize_keys(ServiceEvaluationResult.to_json_map(result)))

      {:error, {:service_not_found, _metadata}} ->
        render_error(
          conn,
          404,
          "service_not_found",
          "Decision Service '#{service_id}' not found in DMN definitions"
        )

      {:error, {:missing_service_input, %{message: message}}} ->
        render_error(conn, 422, "missing_service_input", message)

      {:error, reason} ->
        handle_evaluate_error(conn, reason, nil)
    end
  end

  defp handle_evaluate_error(conn, :decision_definition_not_found, _decision_model_id) do
    render_error(conn, 404, "decision_definition_not_found", "Decision not found")
  end

  defp handle_evaluate_error(conn, :decision_disabled, _decision_model_id) do
    render_error(conn, 422, "decision_definition_disabled", "Decision is disabled")
  end

  defp handle_evaluate_error(conn, :no_version_available, _decision_model_id) do
    render_error(conn, 404, "no_active_version", "No active (non-deleted) version available")
  end

  defp handle_evaluate_error(
         conn,
         {:decision_not_found, %{decision_id: decision_id}},
         _decision_model_id
       ) do
    render_error(
      conn,
      404,
      "decision_not_found",
      "Decision model '#{decision_id}' not found in DMN definitions"
    )
  end

  defp handle_evaluate_error(conn, {:ambiguous_decision, %{message: message}}, _decision_model_id) do
    render_error(conn, 422, "ambiguous_decision", message)
  end

  defp handle_evaluate_error(conn, {:no_decisions, %{message: message}}, _decision_model_id) do
    render_error(conn, 422, "no_decisions", message)
  end

  defp handle_evaluate_error(
         conn,
         {:hit_policy_violation, %{message: message}},
         decision_model_id
       ) do
    render_error(conn, 422, "dmn_evaluation_error", message, decision_model_id: decision_model_id)
  end

  defp handle_evaluate_error(
         conn,
         {:input_expression_eval_failed, %{expression: expression}},
         _decision_model_id
       ) do
    render_error(
      conn,
      422,
      "dmn_evaluation_error",
      "Input expression evaluation failed: #{expression}"
    )
  end

  defp handle_evaluate_error(
         conn,
         {:literal_expression_eval_failed, %{text: text}},
         _decision_model_id
       ) do
    render_error(
      conn,
      422,
      "dmn_evaluation_error",
      "Literal expression evaluation failed: #{text}"
    )
  end

  defp handle_evaluate_error(conn, :not_found, _decision_model_id) do
    render_error(conn, 404, "decision_definition_not_found", "Decision not found in cache")
  end

  defp handle_evaluate_error(
         conn,
         {:drg_cycle, %{decision_ids: decision_ids}},
         _decision_model_id
       ) do
    render_error(conn, 422, "dmn_cycle_error", "Cycle detected in decision dependency graph",
      decision_ids: decision_ids
    )
  end

  defp handle_evaluate_error(conn, {:bkm_cycle, %{bkm_ids: bkm_ids}}, _decision_model_id) do
    render_error(conn, 422, "dmn_cycle_error", "Cycle detected in BKM invocation chain",
      bkm_ids: bkm_ids
    )
  end

  defp handle_evaluate_error(conn, {:bkm_not_found, %{bkm_id: bkm_id}}, _decision_model_id) do
    render_error(conn, 404, "bkm_not_found", "Business Knowledge Model '#{bkm_id}' not found")
  end

  defp handle_evaluate_error(
         conn,
         {:import_not_found, %{namespace: namespace}},
         _decision_model_id
       ) do
    render_error(
      conn,
      422,
      "dmn_evaluation_error",
      "Imported model not found for namespace '#{namespace}'",
      details: "import_not_found"
    )
  end

  defp handle_evaluate_error(conn, {:missing_required_decision, metadata}, decision_model_id) do
    render_error(
      conn,
      422,
      "dmn_evaluation_error",
      "Required decision '#{metadata[:decision_id]}' not found",
      decision_model_id: decision_model_id,
      details: "missing_required_decision"
    )
  end

  defp handle_evaluate_error(conn, {:missing_required_input, metadata}, decision_model_id) do
    render_error(
      conn,
      422,
      "dmn_evaluation_error",
      "Required input '#{metadata[:input_data_name]}' not provided",
      decision_model_id: decision_model_id,
      details: "missing_required_input"
    )
  end

  defp handle_evaluate_error(conn, {:type_coercion_failed, metadata}, decision_model_id) do
    render_error(
      conn,
      422,
      "dmn_evaluation_error",
      "Type coercion failed for input '#{metadata[:input]}'",
      decision_model_id: decision_model_id,
      details: "type_coercion_failed"
    )
  end

  defp handle_evaluate_error(conn, {:expression_eval_failed, _details}, _decision_model_id) do
    render_error(conn, 422, "dmn_evaluation_error", "Expression evaluation failed")
  end

  defp handle_evaluate_error(
         conn,
         {:missing_service_decision, %{decision_id: decision_id}},
         _decision_model_id
       ) do
    render_error(
      conn,
      422,
      "dmn_evaluation_error",
      "Service references missing decision '#{decision_id}'"
    )
  end

  defp handle_evaluate_error(
         conn,
         {:max_import_depth_exceeded, %{depth: depth}},
         _decision_model_id
       ) do
    render_error(
      conn,
      422,
      "dmn_evaluation_error",
      "Maximum import depth exceeded (depth: #{depth})"
    )
  end

  defp handle_evaluate_error(conn, {:input_value_violation, metadata}, _decision_model_id) do
    input_id = metadata[:input_id] || "unknown"

    render_error(
      conn,
      422,
      "input_value_violation",
      "Input '#{input_id}' value does not satisfy inputValues constraint"
    )
  end

  defp handle_evaluate_error(conn, _reason, _decision_model_id) do
    render_error(conn, 422, "dmn_evaluation_error", "DMN evaluation failed")
  end

  # ---------------------------------------------------------------------------
  # GET /decisions
  # ---------------------------------------------------------------------------

  def index(conn, _params) do
    json(conn, Wire.camelize_keys(list_all_decisions()))
  end

  # ---------------------------------------------------------------------------
  # GET /decisions/:model_id
  # ---------------------------------------------------------------------------

  def show(conn, %{"model_id" => model_id}) do
    include_xml? = include_xml_param?(conn)

    case Api.get_decision_by_model_id(model_id) do
      {:ok, definition} ->
        case build_decision_detail(definition, include_xml?) do
          :no_active_versions ->
            render_error(conn, 404, "decision_definition_not_found", "Decision not found")

          detail ->
            json(conn, Wire.camelize_keys(detail))
        end

      :not_found ->
        render_error(conn, 404, "decision_definition_not_found", "Decision not found")
    end
  end

  # ---------------------------------------------------------------------------
  # GET /decisions/:model_id/versions
  # ---------------------------------------------------------------------------

  def versions(conn, %{"model_id" => model_id}) do
    include_xml? = include_xml_param?(conn)

    case Api.get_decision_by_model_id(model_id) do
      {:ok, definition} ->
        entries = build_version_list(definition, include_xml?)
        json(conn, Wire.camelize_keys(entries))

      :not_found ->
        render_error(conn, 404, "decision_definition_not_found", "Decision not found")
    end
  end

  # ---------------------------------------------------------------------------
  # PUT /decisions/:model_id/enable
  # ---------------------------------------------------------------------------

  def enable(conn, %{"model_id" => model_id}) do
    toggle_enabled(conn, model_id, true)
  end

  # ---------------------------------------------------------------------------
  # PUT /decisions/:model_id/disable
  # ---------------------------------------------------------------------------

  def disable(conn, %{"model_id" => model_id}) do
    toggle_enabled(conn, model_id, false)
  end

  # ---------------------------------------------------------------------------
  # DELETE /decisions/:model_id/versions/:version
  # ---------------------------------------------------------------------------

  def delete_version(conn, %{"model_id" => model_id, "version" => version}) do
    case Api.delete_decision_version(model_id, version, deployer_identity(conn),
           source: rest_source(conn)
         ) do
      {:ok, _updated} ->
        send_resp(conn, 204, "")

      {:error, :not_found} ->
        render_error(conn, 404, "not_found", "Version not found")

      {:error, :forbidden, details} ->
        forbidden(conn, details[:required_claim] || "delete_dmn", details)

      {:error, reason} ->
        Logger.error("DMN version delete failed: #{inspect(reason)}")
        render_error(conn, 500, "internal_error", "Unexpected error during DMN version delete")
    end
  end

  # ---------------------------------------------------------------------------
  # DELETE /decisions/:model_id — undeploy (delete all versions)
  # ---------------------------------------------------------------------------

  def undeploy(conn, %{"model_id" => model_id}) do
    case Api.undeploy_decision(model_id, deployer_identity(conn), source: rest_source(conn)) do
      :ok ->
        send_resp(conn, 204, "")

      {:error, :not_found} ->
        render_error(conn, 404, "not_found", "Decision not found")

      {:error, :no_active_versions} ->
        render_error(conn, 404, "not_found", "No active versions to undeploy")

      {:error, :forbidden, details} ->
        forbidden(conn, details[:required_claim] || "delete_dmn", details)

      {:error, reason} ->
        Logger.error("DMN undeploy failed: #{inspect(reason)}")
        render_error(conn, 500, "internal_error", "Unexpected error during DMN undeploy")
    end
  end

  # ===========================================================================
  # Private helpers
  # ===========================================================================

  defp extract_dmn_entries(conn) do
    with %{"sources" => sources} <- conn.body_params,
         true <- is_list(sources) and sources != [],
         true <- Enum.all?(sources, &is_binary/1) do
      entries =
        sources
        |> Enum.with_index(1)
        |> Enum.map(fn {xml, index} ->
          %{filename: "source_#{index}.dmn", xml: xml}
        end)

      {:ok, entries}
    else
      _ -> {:error, :invalid_sources}
    end
  end

  defp include_xml_param?(conn) do
    conn = Plug.Conn.fetch_query_params(conn)
    conn.query_params["includeXml"] == "true"
  end

  defp list_all_decisions do
    case Api.list_decision_definitions() do
      {:ok, []} -> []
      {:ok, definitions} -> build_decision_listing(definitions)
      _ -> []
    end
  end

  defp build_decision_listing(definitions) do
    definition_ids = Enum.map(definitions, & &1.id)
    latest_by_definition = Api.find_latest_decision_versions_by_definition_ids(definition_ids)
    Enum.flat_map(definitions, &to_decision_listing_entry(&1, latest_by_definition))
  end

  defp to_decision_listing_entry(definition, latest_by_definition) do
    case Map.get(latest_by_definition, definition.id) do
      nil ->
        []

      version ->
        [
          %{
            id: definition.decision_definition_id,
            version: version.version,
            name: definition.name,
            enabled: definition.enabled,
            deployed_at: version.deployed_at
          }
        ]
    end
  end

  defp build_decision_detail(definition, include_xml?) do
    case Api.get_latest_decision_version(definition.id) do
      {:ok, version} ->
        base = %{
          id: definition.decision_definition_id,
          version: version.version,
          name: definition.name,
          enabled: definition.enabled,
          deployed_at: version.deployed_at,
          deployer: version.deployer
        }

        if include_xml?, do: Map.put(base, :dmn_xml, version.dmn_xml), else: base

      _ ->
        :no_active_versions
    end
  end

  defp build_version_list(definition, include_xml?) do
    definition.id
    |> Api.list_decision_versions_for_definition()
    |> Enum.map(&format_version_entry(&1, definition, include_xml?))
  end

  defp format_version_entry(version, definition, include_xml?) do
    entry = %{
      id: definition.decision_definition_id,
      version_id: version.id,
      version: version.version,
      name: definition.name,
      enabled: definition.enabled,
      deployed_at: version.deployed_at,
      deployer: version.deployer
    }

    if include_xml?, do: Map.put(entry, :dmn_xml, version.dmn_xml), else: entry
  end

  defp toggle_enabled(conn, model_id, enabled_value) do
    case Api.get_decision_by_model_id(model_id) do
      {:ok, definition} ->
        case Api.update_decision_enabled(definition, enabled_value, caller_identity(conn)) do
          {:ok, _updated} ->
            send_resp(conn, 204, "")

          {:error, :forbidden, details} ->
            forbidden(conn, details[:required_claim] || "deploy_dmn", details)

          {:error, reason} ->
            Logger.error("DMN enable/disable failed: #{inspect(reason)}")

            render_error(conn, 500, "internal_error", "Unexpected error during DMN enable/disable")
        end

      :not_found ->
        render_error(conn, 404, "not_found", "Decision not found")
    end
  end

  # ---------------------------------------------------------------------------
  # Authorization helpers
  # ---------------------------------------------------------------------------

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
      resource: "decision"
    )
  end
end
