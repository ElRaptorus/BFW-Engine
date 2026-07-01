defmodule EvilEngine.Persistence.Resources.DecisionCatalogTest do
  @moduledoc """
  Ash catalog tests for DMN decision definitions and versions.

  Verifies deploy persistence, version lookup, and soft-delete filtering
  on the primary :read action (P9 invariant).
  """

  use EvilEngine.Persistence.DataCase, async: false

  require Ash.Query

  alias EvilEngine.Persistence.Api, as: Domain
  alias EvilEngine.Persistence.ExecutionAdapter
  alias EvilEngine.Persistence.Resources.DecisionDefinition
  alias EvilEngine.Persistence.Resources.DecisionVersion

  @decision_model_id "discount-rules"

  describe "DecisionDefinition" do
    test "create persists definition keyed by decision_definition_id" do
      attributes = %{
        decision_definition_id: @decision_model_id,
        name: "Discount Rules"
      }

      assert {:ok, definition} =
               DecisionDefinition
               |> Ash.Changeset.for_create(:create, attributes)
               |> Ash.create(domain: Domain, authorize?: false)

      assert definition.decision_definition_id == @decision_model_id
      assert definition.name == "Discount Rules"
      assert definition.enabled == true
    end

    test "read by decision_definition_id via identity filter" do
      unique_key = "lookup_#{Ash.UUIDv7.generate()}"

      assert {:ok, created} =
               DecisionDefinition
               |> Ash.Changeset.for_create(:create, %{
                 decision_definition_id: unique_key,
                 name: "Lookup"
               })
               |> Ash.create(domain: Domain, authorize?: false)

      assert {:ok, [read_back]} =
               DecisionDefinition
               |> Ash.Query.filter(decision_definition_id == ^unique_key)
               |> Ash.read(domain: Domain, authorize?: false)

      assert read_back.id == created.id
    end
  end

  describe "DecisionVersion" do
    setup do
      {:ok, definition} =
        DecisionDefinition
        |> Ash.Changeset.for_create(:create, %{
          decision_definition_id: "version_parent_#{Ash.UUIDv7.generate()}",
          name: "Parent"
        })
        |> Ash.create(domain: Domain, authorize?: false)

      %{definition: definition}
    end

    test "create with FK to existing definition persists version row", %{definition: definition} do
      assert {:ok, version} =
               DecisionVersion
               |> Ash.Changeset.for_create(:create, %{
                 decision_definition_id: definition.id,
                 version: "1.0.0",
                 dmn_xml: "<definitions/>"
               })
               |> Ash.create(domain: Domain, authorize?: false)

      assert version.decision_definition_id == definition.id
      assert version.version == "1.0.0"
      assert version.dmn_xml == "<definitions/>"
      assert version.deleted == false
    end

    test "has_many :versions loads correctly", %{definition: definition} do
      assert {:ok, _} =
               DecisionVersion
               |> Ash.Changeset.for_create(:create, %{
                 decision_definition_id: definition.id,
                 version: "2.0.0",
                 dmn_xml: "<definitions/>"
               })
               |> Ash.create(domain: Domain, authorize?: false)

      assert {:ok, [loaded]} =
               DecisionDefinition
               |> Ash.Query.filter(id == ^definition.id)
               |> Ash.Query.load(:versions)
               |> Ash.read(domain: Domain, authorize?: false)

      assert [version_row] = loaded.versions
      assert version_row.version == "2.0.0"
    end

    test "soft-deleted version is filtered from primary :read", %{definition: definition} do
      assert {:ok, version} =
               DecisionVersion
               |> Ash.Changeset.for_create(:create, %{
                 decision_definition_id: definition.id,
                 version: "3.0.0",
                 dmn_xml: "<definitions/>"
               })
               |> Ash.create(domain: Domain, authorize?: false)

      assert {:ok, _updated} =
               Ash.update(
                 version,
                 %{
                   deleted: true,
                   deleted_at: DateTime.utc_now(),
                   deleted_by: %{"id" => "admin"}
                 },
                 action: :soft_delete,
                 authorize?: false
               )

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Ash.get(DecisionVersion, version.id, authorize?: false)
    end

    test "load_dmn_xml returns XML for an active version", %{definition: definition} do
      dmn_xml = "<definitions id=\"Decision_1\"/>"

      assert {:ok, version} =
               DecisionVersion
               |> Ash.Changeset.for_create(:create, %{
                 decision_definition_id: definition.id,
                 version: "4.0.0",
                 dmn_xml: dmn_xml
               })
               |> Ash.create(domain: Domain, authorize?: false)

      assert {:ok, ^dmn_xml} = ExecutionAdapter.load_dmn_xml(version.id)
    end

    test "load_dmn_xml returns :not_found for soft-deleted version", %{definition: definition} do
      assert {:ok, version} =
               DecisionVersion
               |> Ash.Changeset.for_create(:create, %{
                 decision_definition_id: definition.id,
                 version: "5.0.0",
                 dmn_xml: "<definitions/>"
               })
               |> Ash.create(domain: Domain, authorize?: false)

      assert {:ok, _updated} =
               Ash.update(
                 version,
                 %{
                   deleted: true,
                   deleted_at: DateTime.utc_now(),
                   deleted_by: %{"id" => "admin"}
                 },
                 action: :soft_delete,
                 authorize?: false
               )

      assert {:error, :not_found} = ExecutionAdapter.load_dmn_xml(version.id)
    end
  end
end
