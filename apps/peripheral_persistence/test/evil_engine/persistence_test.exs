defmodule EvilEngine.PersistenceTest do
  use ExUnit.Case, async: true

  alias Ash.Domain.Info, as: DomainInfo
  alias Ash.Resource.Info, as: ResourceInfo

  alias EvilEngine.Persistence.Resources.FlowNodeInstance
  alias EvilEngine.Persistence.Resources.GatewayPendingArrival
  alias EvilEngine.Persistence.Resources.ProcessInstance

  @execution_resources [ProcessInstance, FlowNodeInstance, GatewayPendingArrival]

  test "the Ash domain declares the execution-state resources" do
    resources = DomainInfo.resources(EvilEngine.Persistence.Api)

    for resource <- @execution_resources do
      assert resource in resources, "#{inspect(resource)} missing from domain"
    end
  end

  test "the Repo module is declared" do
    assert Code.ensure_loaded?(EvilEngine.Persistence.Repo)
  end

  describe "schema guard — ProcessInstance" do
    test "has no final_token attribute" do
      attribute_names =
        ProcessInstance
        |> ResourceInfo.attributes()
        |> Enum.map(& &1.name)

      refute :final_token in attribute_names,
             "process_instances must NOT have a final_token column"
    end

    test "has started_with_context but not final_token" do
      attribute_names =
        ProcessInstance
        |> ResourceInfo.attributes()
        |> Enum.map(& &1.name)

      assert :started_with_context in attribute_names
      refute :final_token in attribute_names
    end
  end

  describe "schema guard — no active_tokens resource" do
    test "no Ash resource maps to an active_tokens table" do
      resources = DomainInfo.resources(EvilEngine.Persistence.Api)

      for resource <- resources do
        table = AshPostgres.DataLayer.Info.table(resource)

        refute table == "active_tokens",
               "the active_tokens table must not exist — found resource #{inspect(resource)}"
      end
    end
  end

  describe "FlowNodeInstance" do
    test "previous_flow_node_instance_ids is a uuid array" do
      attribute =
        FlowNodeInstance
        |> ResourceInfo.attributes()
        |> Enum.find(&(&1.name == :previous_flow_node_instance_ids))

      assert attribute, "missing previous_flow_node_instance_ids attribute"
      assert attribute.type == {:array, Ash.Type.UUID}
    end
  end

  describe "GatewayPendingArrival" do
    test "has a unique identity on gateway_flow_node_instance_id + source_branch_sequence_flow_id" do
      identities = ResourceInfo.identities(GatewayPendingArrival)
      identity_keys = Enum.map(identities, & &1.keys)

      assert [:gateway_flow_node_instance_id, :source_branch_sequence_flow_id] in identity_keys,
             "gateway_pending_arrivals must enforce UNIQUE(gateway_flow_node_instance_id, source_branch_sequence_flow_id)"
    end
  end
end
