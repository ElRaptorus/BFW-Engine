defmodule BfwEngine.Integration.Graphql.GraphqlModelGraphWp7Test do
  @moduledoc """
  Phase 6.1 WP-7 tests (v)-(vii) for the BPMN Model graph that need a live
  HTTP/GraphQL pipeline: Dataloader batching, authorization, and cold-cache
  behaviour plus the depth-limit regression for the canonical debugger query.

  Tests (i) and (iv) are pure schema-introspection unit tests — see
  `BfwEngineWeb.Graphql.ModelGraphIntrospectionTest` in `apps/api_web`.
  Test (ii)'s flattening half is `ModelResolversTest`; the HTTP half
  (inner-scope `flowNode` via a child PI) is in this file. Test (iii)
  (extension manifest corpus round-trip) is
  `BfwEngine.BPMN.ExtensionManifestTest`.
  """
  use BfwEngine.ExecutionCase, async: false

  @moduletag :integration

  alias BfwEngine.BPMN.ModelCache

  @admin_claims %{"sub" => "admin", "zeeky_boogie_doog" => true}
  @lane_default_claims %{"sub" => "lane-default-user", "lane:default" => "write"}
  # `user_task_with_lane.bpmn` puts every flow node (including the start
  # event) in a lane named "Management" — the starter must hold that claim
  # or `Api.check_start_lane/4` rejects the start with `{:error, :not_found}`.
  @lane_management_claims %{"sub" => "lane-management-user", "lane:Management" => "write"}

  @flow_node_query """
  query($id: ID!) {
    getFlowNodeInstance(id: $id) {
      id
      flowNodeId
      flowNode { id type }
    }
  }
  """

  # -------------------------------------------------------------------
  # Test (v) — Dataloader batching
  # -------------------------------------------------------------------

  describe "test (v) — Dataloader batching" do
    test "a debugger-shaped query resolving flowNode for every FNI of a PI issues exactly one ModelCache.fetch/1 per distinct process_version_id" do
      process_instance_id = http_deploy_and_start("chained_tasks.bpmn", "ChainedTasks")
      wait_for_process_instance(process_instance_id)

      {200, list_body} =
        http_graphql(
          """
          query($piId: ID!) {
            flowNodeInstances(filter: {processInstanceId: {eq: $piId}}) {
              results { id }
            }
          }
          """,
          %{"piId" => process_instance_id},
          @admin_claims
        )

      fni_ids = list_body["data"]["flowNodeInstances"]["results"] |> Enum.map(& &1["id"])
      # Start + 3 tasks + End, at minimum.
      assert length(fni_ids) >= 5

      query = """
      query {
        #{Enum.map_join(fni_ids, "\n", fn id -> "fni_#{sanitize(id)}: getFlowNodeInstance(id: \"#{id}\") { id flowNode { id type } } " end)}
      }
      """

      test_pid = self()
      handler_id = {__MODULE__, :batching, make_ref()}

      :telemetry.attach(
        handler_id,
        [:bfw_engine, :model_cache, :fetch],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:model_cache_fetch, metadata.process_version_id})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {200, body} = http_graphql(query, %{}, @admin_claims)
      refute Map.has_key?(body, "errors")

      fetched_version_ids = collect_fetch_events([])

      distinct_version_ids = Enum.uniq(fetched_version_ids)
      assert length(distinct_version_ids) == 1, "expected exactly one distinct process_version_id to be fetched"

      occurrences_for_version =
        Enum.count(fetched_version_ids, &(&1 == hd(distinct_version_ids)))

      assert occurrences_for_version == 1,
             "expected exactly one ModelCache.fetch/1 for the shared process_version_id " <>
               "across #{length(fni_ids)} FNIs in a single request, got #{occurrences_for_version}"
    end
  end

  # -------------------------------------------------------------------
  # Test (vi) — Authorization negative test
  # -------------------------------------------------------------------

  describe "test (ii) — flowNode reaches nested subprocess scopes" do
    test "FlowNodeInstance.flowNode resolves an inner-scope node identically to allFlowNodes" do
      process_instance_id =
        http_deploy_and_start("embedded_subprocess_happy_path.bpmn", "EmbeddedSubprocessHappyPath")

      wait_for_process_instance(process_instance_id)

      {200, children_body} =
        http_graphql(
          """
          query($parentId: ID!) {
            processInstances(filter: {parentProcessInstanceId: {eq: $parentId}}) {
              results { id }
            }
          }
          """,
          %{"parentId" => process_instance_id},
          @admin_claims
        )

      refute Map.has_key?(children_body, "errors")
      child_results = children_body["data"]["processInstances"]["results"]
      assert child_results != []
      child_id = hd(child_results)["id"]

      {200, list_body} =
        http_graphql(
          """
          query($processInstanceId: ID!) {
            flowNodeInstances(filter: {processInstanceId: {eq: $processInstanceId}}) {
              results { id flowNodeId }
            }
          }
          """,
          %{"processInstanceId" => child_id},
          @admin_claims
        )

      refute Map.has_key?(list_body, "errors")
      inner_fni = Enum.find(list_body["data"]["flowNodeInstances"]["results"], &(&1["flowNodeId"] == "Sub_Task"))
      assert inner_fni != nil

      {200, body} =
        http_graphql(
          """
          query($id: ID!) {
            getFlowNodeInstance(id: $id) {
              id
              flowNodeId
              flowNode {
                id
                type
                parentSubProcessId
              }
            }
          }
          """,
          %{"id" => inner_fni["id"]},
          @admin_claims
        )

      refute Map.has_key?(body, "errors")
      flow_node = body["data"]["getFlowNodeInstance"]["flowNode"]
      assert flow_node["id"] == "Sub_Task"
      assert flow_node["type"] == "TASK"
      assert flow_node["parentSubProcessId"] == "SubProcess_1"
    end
  end

  describe "test (vi) — authorization" do
    test "an unauthenticated caller cannot reach processModel through ProcessVersion" do
      {201, deploy_body} = http_deploy("linear_start_end.bpmn")
      [deployed] = deploy_body["deployed"]

      {200, list_body} =
        http_graphql(
          "query { processVersions { results { id version bpmnXml } } }",
          %{},
          @admin_claims
        )

      found =
        Enum.find(list_body["data"]["processVersions"]["results"], fn version ->
          version["version"] == deployed["version"] and
            is_binary(version["bpmnXml"]) and
            String.contains?(version["bpmnXml"], "LinearStartEnd")
        end)

      query = """
      query($id: ID!) { getProcessVersion(id: $id) { id processModel { id } } }
      """

      json_body = Jason.encode!(%{"query" => query, "variables" => %{"id" => found["id"]}})

      conn =
        Plug.Test.conn(:post, "/api/v1/graphql", json_body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> route()

      assert conn.status in [401, 403]
    end

    test "an actor who cannot read a FlowNodeInstance also cannot reach flowNode/processVersion through it" do
      {201, _} = http_deploy("user_task_with_lane.bpmn")
      {201, start_body} = http_start("LanedUserTask", %{}, @lane_management_claims)
      process_instance_id = start_body["processInstanceId"]

      {:ok, fni} = await_waiting_flow_node_instance(process_instance_id, "user_task")

      # The starter's own lane can reach the flowNode.
      {200, visible} = http_graphql(@flow_node_query, %{"id" => fni.id}, @lane_management_claims)
      refute Map.has_key?(visible, "errors")
      assert visible["data"]["getFlowNodeInstance"]["flowNode"]["id"] != nil

      # A different, unrelated lane cannot see the FNI at all — the record
      # itself resolves to null before the flowNode/processVersion
      # resolvers ever run.
      {200, invisible} = http_graphql(@flow_node_query, %{"id" => fni.id}, @lane_default_claims)
      refute Map.has_key?(invisible, "errors")
      assert invisible["data"]["getFlowNodeInstance"] == nil
    end
  end

  # -------------------------------------------------------------------
  # Test (vii) — Cold-cache behaviour + depth/complexity regression
  # -------------------------------------------------------------------

  describe "test (vii) — cold-cache behaviour" do
    test "resolver on an evicted ModelCache entry triggers the DB-backed loader and still succeeds" do
      previous_loader = Application.get_env(:core_bpmn, :model_cache_loader)

      Application.put_env(
        :core_bpmn,
        :model_cache_loader,
        {BfwEngine.Persistence.ExecutionAdapter, :load_bpmn_xml}
      )

      on_exit(fn ->
        if previous_loader do
          Application.put_env(:core_bpmn, :model_cache_loader, previous_loader)
        else
          Application.delete_env(:core_bpmn, :model_cache_loader)
        end
      end)

      {201, deploy_body} = http_deploy("linear_start_end.bpmn")
      [deployed] = deploy_body["deployed"]

      {200, list_body} =
        http_graphql(
          "query { processVersions { results { id version bpmnXml } } }",
          %{},
          @admin_claims
        )

      found =
        Enum.find(list_body["data"]["processVersions"]["results"], fn version ->
          version["version"] == deployed["version"] and
            is_binary(version["bpmnXml"]) and
            String.contains?(version["bpmnXml"], "LinearStartEnd")
        end)

      assert found != nil

      # Evict the warm cache entry inserted at deploy time, so the resolver
      # must go through the cold-miss DB-backed loader path.
      ModelCache.delete(found["id"])
      assert found["id"] not in ModelCache.list_cached_ids()

      {200, body} =
        http_graphql(
          "query($id: ID!) { getProcessVersion(id: $id) { id processModel { id name } } }",
          %{"id" => found["id"]},
          @admin_claims
        )

      refute Map.has_key?(body, "errors")
      assert body["data"]["getProcessVersion"]["processModel"]["name"] == "Linear Start End"
    end
  end

  describe "test (vii) — depth/complexity limits accommodate the canonical debugger query" do
    test "the canonical getProcessVersionWithModel-shaped query (buildProcessModelSelection depth 4) passes the depth limit" do
      query = canonical_process_model_query()

      {201, deploy_body} = http_deploy("linear_start_end.bpmn")
      [deployed] = deploy_body["deployed"]

      {200, list_body} =
        http_graphql(
          "query { processVersions { results { id version bpmnXml } } }",
          %{},
          @admin_claims
        )

      found =
        Enum.find(list_body["data"]["processVersions"]["results"], fn version ->
          version["version"] == deployed["version"] and
            is_binary(version["bpmnXml"]) and
            String.contains?(version["bpmnXml"], "LinearStartEnd")
        end)

      {200, body} = http_graphql(query, %{"id" => found["id"]}, @admin_claims)

      refute Map.has_key?(body, "errors"),
             "canonical debugger query returned GraphQL errors: #{inspect(body["errors"])}"

      process_model = body["data"]["getProcessVersion"]["processModel"]
      assert process_model["id"] != nil

      configured_depth = Application.get_env(:api_web, :graphql_max_depth, 16)

      assert configured_depth >= 16,
             "BFE_GRAPHQL_MAX_DEPTH was re-tuned to 16 for SubProcessNode.flowNodes recursion; " <>
               "got #{configured_depth}"
    end
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp collect_fetch_events(acc) do
    receive do
      {:model_cache_fetch, process_version_id} -> collect_fetch_events([process_version_id | acc])
    after
      200 -> acc
    end
  end

  defp sanitize(id), do: String.replace(id, "-", "_")

  # Mirrors `buildProcessModelSelection(4)` from
  # `packages/js/sdk/src/graphql/model-fields.ts`, at one representative
  # recursion level (SubProcessNode.flowNodes nested 4 deep), to pin the
  # depth limit against the shape the TS client actually sends.
  #
  # Do not add empty inline fragments (`... on TaskNode { }`). GraphQL
  # forbids empty selection sets; Absinthe reports `syntax error before: '}'`.
  # Types with no extra fields are covered by the FlowNode interface fields.
  defp canonical_process_model_query do
    """
    query($id: ID!) {
      getProcessVersion(id: $id) {
        id
        processModel {
          id
          name
          flowNodes {
            id
            name
            type
            dataContracts { direction jsonSchema }
            multiInstance { isSequential collectionExpression }
            ... on SubProcessNode {
              flowNodes {
                id
                ... on SubProcessNode {
                  flowNodes {
                    id
                    ... on SubProcessNode {
                      flowNodes {
                        id
                        ... on SubProcessNode {
                          flowNodes {
                            id
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
          allFlowNodes { id type parentSubProcessId }
        }
      }
    }
    """
  end
end
