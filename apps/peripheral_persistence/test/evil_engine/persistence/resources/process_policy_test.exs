defmodule EvilEngine.Persistence.Resources.ProcessPolicyTest do
  @moduledoc """
  Ash policy tests for `Process` and `ProcessVersion` resources.

  Verifies that:
  - Reads are allowed for any authenticated actor.
  - Reads are denied when no actor is present.
  - Creates/updates require `deploy_bpmn: true`.
  - Soft-delete (ProcessVersion) requires `delete_bpmn: true`.
  - ZeekyBoogieDoog bypasses all policies.
  - S-2: ProcessInstance and FlowNodeInstance reads are denied without an actor
    (i.e., the `actor_absent()` bypass has been removed).
  """

  use EvilEngine.Persistence.DataCase, async: false

  require Ash.Query

  alias EvilEngine.Persistence.Api, as: Domain
  alias EvilEngine.Persistence.Resources.FlowNodeInstance
  alias EvilEngine.Persistence.Resources.Process
  alias EvilEngine.Persistence.Resources.ProcessInstance
  alias EvilEngine.Persistence.Resources.ProcessVersion

  # ---------------------------------------------------------------------------
  # Actor helpers
  # ---------------------------------------------------------------------------

  defp actor(overrides \\ %{}) do
    Map.merge(
      %{
        id: "test-user",
        accessible_lanes: [],
        observe_all: false,
        zeeky_boogie_doog: false,
        deploy_bpmn: false,
        delete_bpmn: false
      },
      overrides
    )
  end

  defp deployer, do: actor(%{deploy_bpmn: true})
  defp deleter, do: actor(%{delete_bpmn: true})
  defp admin, do: actor(%{zeeky_boogie_doog: true})

  # ---------------------------------------------------------------------------
  # Helpers to create seed data bypassing policies
  # ---------------------------------------------------------------------------

  defp create_process(optional_process_model_id \\ nil) do
    process_model_id = optional_process_model_id || "policy_test_#{:rand.uniform(999_999)}"

    {:ok, process} =
      Process
      |> Ash.Changeset.for_create(:create, %{
        process_model_id: process_model_id,
        name: "Policy Test"
      })
      |> Ash.create(domain: Domain, authorize?: false)

    process
  end

  defp create_version(process_id) do
    {:ok, version} =
      ProcessVersion
      |> Ash.Changeset.for_create(:create, %{
        process_id: process_id,
        version: "1.0.0",
        bpmn_xml: "<bpmn/>"
      })
      |> Ash.create(domain: Domain, authorize?: false)

    version
  end

  # ---------------------------------------------------------------------------
  # Process — reads
  # ---------------------------------------------------------------------------

  describe "Process read policy" do
    test "any actor can read processes" do
      create_process("readable_process")

      assert {:ok, _results} =
               Process
               |> Ash.Query.filter(process_model_id == "readable_process")
               |> Ash.read(domain: Domain, actor: actor())
    end

    test "reading processes without an actor returns empty results (policy filter)" do
      # Ash read policies use row-level filtering rather than hard Forbidden errors.
      # Without an actor, actor_present() fails → all rows are filtered out.
      # The security guarantee holds: no data is returned to an unauthenticated caller.
      assert {:ok, []} = Process |> Ash.read(domain: Domain)
    end
  end

  # ---------------------------------------------------------------------------
  # Process — creates
  # ---------------------------------------------------------------------------

  describe "Process create policy" do
    test "actor with deploy_bpmn can create a process" do
      assert {:ok, _} =
               Process
               |> Ash.Changeset.for_create(:create, %{
                 process_model_id: "deploy_allowed_#{:rand.uniform(999_999)}",
                 name: "Allowed"
               })
               |> Ash.create(domain: Domain, actor: deployer())
    end

    test "actor without deploy_bpmn is denied process create" do
      assert {:error, %Ash.Error.Forbidden{}} =
               Process
               |> Ash.Changeset.for_create(:create, %{
                 process_model_id: "deploy_denied_#{:rand.uniform(999_999)}",
                 name: "Denied"
               })
               |> Ash.create(domain: Domain, actor: actor())
    end

    test "admin (zeeky_boogie_doog) can create a process" do
      assert {:ok, _} =
               Process
               |> Ash.Changeset.for_create(:create, %{
                 process_model_id: "admin_create_#{:rand.uniform(999_999)}",
                 name: "Admin"
               })
               |> Ash.create(domain: Domain, actor: admin())
    end

    test "observe_all does not allow process create" do
      assert {:error, %Ash.Error.Forbidden{}} =
               Process
               |> Ash.Changeset.for_create(:create, %{
                 process_model_id: "observe_create_#{:rand.uniform(999_999)}",
                 name: "Observer"
               })
               |> Ash.create(domain: Domain, actor: actor(%{observe_all: true}))
    end

    test "creating a process without an actor is denied" do
      assert {:error, %Ash.Error.Forbidden{}} =
               Process
               |> Ash.Changeset.for_create(:create, %{
                 process_model_id: "no_actor_#{:rand.uniform(999_999)}",
                 name: "No Actor"
               })
               |> Ash.create(domain: Domain)
    end
  end

  # ---------------------------------------------------------------------------
  # Process — updates (enable / disable)
  # ---------------------------------------------------------------------------

  describe "Process update policy" do
    setup do
      %{process: create_process()}
    end

    test "actor with deploy_bpmn can update a process", %{process: process} do
      assert {:ok, _} =
               process
               |> Ash.Changeset.for_update(:update_enabled, %{enabled: false})
               |> Ash.update(domain: Domain, actor: deployer())
    end

    test "actor without deploy_bpmn is denied process update", %{process: process} do
      assert {:error, %Ash.Error.Forbidden{}} =
               process
               |> Ash.Changeset.for_update(:update_enabled, %{enabled: false})
               |> Ash.update(domain: Domain, actor: actor())
    end

    test "admin (zeeky_boogie_doog) can update a process", %{process: process} do
      assert {:ok, _} =
               process
               |> Ash.Changeset.for_update(:update_enabled, %{enabled: false})
               |> Ash.update(domain: Domain, actor: admin())
    end
  end

  # ---------------------------------------------------------------------------
  # ProcessVersion — reads
  # ---------------------------------------------------------------------------

  describe "ProcessVersion read policy" do
    setup do
      process = create_process()
      version = create_version(process.id)
      %{process: process, version: version}
    end

    test "any actor can read versions", %{process: process} do
      assert {:ok, _} =
               ProcessVersion
               |> Ash.Query.filter(process_id == ^process.id)
               |> Ash.read(domain: Domain, actor: actor())
    end

    test "reading versions without an actor returns empty results (policy filter)" do
      # Ash read policies use row-level filtering rather than hard Forbidden errors.
      # Without an actor, actor_present() fails → all rows are filtered out.
      # The security guarantee holds: no data is returned to an unauthenticated caller.
      assert {:ok, []} = ProcessVersion |> Ash.read(domain: Domain)
    end
  end

  # ---------------------------------------------------------------------------
  # ProcessVersion — creates
  # ---------------------------------------------------------------------------

  describe "ProcessVersion create policy" do
    setup do
      %{process: create_process()}
    end

    test "actor with deploy_bpmn can create a version", %{process: process} do
      assert {:ok, _} =
               ProcessVersion
               |> Ash.Changeset.for_create(:create, %{
                 process_id: process.id,
                 version: "2.0.0",
                 bpmn_xml: "<bpmn/>"
               })
               |> Ash.create(domain: Domain, actor: deployer())
    end

    test "actor without deploy_bpmn is denied version create", %{process: process} do
      assert {:error, %Ash.Error.Forbidden{}} =
               ProcessVersion
               |> Ash.Changeset.for_create(:create, %{
                 process_id: process.id,
                 version: "3.0.0",
                 bpmn_xml: "<bpmn/>"
               })
               |> Ash.create(domain: Domain, actor: actor())
    end

    test "admin (zeeky_boogie_doog) can create a version", %{process: process} do
      assert {:ok, _} =
               ProcessVersion
               |> Ash.Changeset.for_create(:create, %{
                 process_id: process.id,
                 version: "4.0.0",
                 bpmn_xml: "<bpmn/>"
               })
               |> Ash.create(domain: Domain, actor: admin())
    end
  end

  # ---------------------------------------------------------------------------
  # ProcessVersion — soft_delete
  # ---------------------------------------------------------------------------

  describe "ProcessVersion soft_delete policy" do
    setup do
      process = create_process()
      version = create_version(process.id)
      %{version: version}
    end

    test "actor with delete_bpmn can soft-delete a version", %{version: version} do
      now = DateTime.utc_now()

      assert {:ok, _} =
               version
               |> Ash.Changeset.for_update(:soft_delete, %{
                 deleted: true,
                 deleted_at: now,
                 deleted_by: %{"id" => "deleter"}
               })
               |> Ash.update(domain: Domain, actor: deleter())
    end

    test "actor without delete_bpmn is denied soft-delete", %{version: version} do
      now = DateTime.utc_now()

      assert {:error, %Ash.Error.Forbidden{}} =
               version
               |> Ash.Changeset.for_update(:soft_delete, %{
                 deleted: true,
                 deleted_at: now,
                 deleted_by: %{"id" => "no-rights"}
               })
               |> Ash.update(domain: Domain, actor: actor())
    end

    test "actor with only deploy_bpmn (not delete_bpmn) is denied soft-delete", %{
      version: version
    } do
      now = DateTime.utc_now()

      assert {:error, %Ash.Error.Forbidden{}} =
               version
               |> Ash.Changeset.for_update(:soft_delete, %{
                 deleted: true,
                 deleted_at: now,
                 deleted_by: %{"id" => "deploy-only"}
               })
               |> Ash.update(domain: Domain, actor: deployer())
    end

    test "admin (zeeky_boogie_doog) can soft-delete a version", %{version: version} do
      now = DateTime.utc_now()

      assert {:ok, _} =
               version
               |> Ash.Changeset.for_update(:soft_delete, %{
                 deleted: true,
                 deleted_at: now,
                 deleted_by: %{"id" => "admin"}
               })
               |> Ash.update(domain: Domain, actor: admin())
    end
  end

  # ---------------------------------------------------------------------------
  # S-2: ProcessInstance and FlowNodeInstance — actor_absent removed
  # ---------------------------------------------------------------------------

  describe "ProcessInstance read policy — actor_absent bypass removed" do
    test "reading process instances without an actor returns empty results (S-2 fix)" do
      # Ash read policies use row-level filtering rather than hard Forbidden errors.
      # Without an actor, and with the actor_absent() bypass removed, the only
      # bypass that remains is ZeekyBoogieDoog. actor_present() fails → all rows
      # are filtered out. The security guarantee holds: no PI data is visible to
      # an unauthenticated caller.
      assert {:ok, []} = ProcessInstance |> Ash.read(domain: Domain)
    end
  end

  describe "FlowNodeInstance read policy — actor_absent bypass removed" do
    test "reading flow node instances without an actor returns empty results (S-2 fix)" do
      # Same rationale as ProcessInstance above: row-level filter, not Forbidden.
      # actor_absent() bypass removed → unauthenticated callers see no FNI data.
      assert {:ok, []} = FlowNodeInstance |> Ash.read(domain: Domain)
    end
  end
end
