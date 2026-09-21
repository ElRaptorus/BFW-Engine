defmodule BfwEngine.Persistence.Resources.CatalogTest do
  @moduledoc """
  Ash catalog resource tests against PostgreSQL.

  If tests fail with a missing `processes` table, run `MIX_ENV=test mix ecto.reset`.

  All Ash calls use `authorize?: false` because this test suite exercises
  persistence behaviour, not authorization rules. Policy tests live in
  `apps/api_web/test/bfw_engine_web/http/policies/process_catalog_policy_test.exs`.
  """

  use BfwEngine.Persistence.DataCase, async: false

  require Ash.Query

  alias BfwEngine.Persistence.Api, as: Domain
  alias BfwEngine.Persistence.Resources.Process
  alias BfwEngine.Persistence.Resources.ProcessVersion

  @process_model_id "catalog_test_process"

  describe "Process" do
    test "create with valid attributes persists and returns struct" do
      attributes = %{process_model_id: @process_model_id, name: "Catalog Test"}

      assert {:ok, process} =
               Process
               |> Ash.Changeset.for_create(:create, attributes)
               |> Ash.create(domain: Domain, authorize?: false)

      assert process.process_model_id == @process_model_id
      assert process.name == "Catalog Test"
      assert process.enabled == true
      assert %DateTime{} = process.created_at
    end

    test "duplicate process_model_id returns error" do
      attributes = %{process_model_id: "dup_key_process", name: "First"}

      assert {:ok, _} =
               Process
               |> Ash.Changeset.for_create(:create, attributes)
               |> Ash.create(domain: Domain, authorize?: false)

      assert {:error, _} =
               Process
               |> Ash.Changeset.for_create(:create, %{
                 process_model_id: "dup_key_process",
                 name: "Second"
               })
               |> Ash.create(domain: Domain, authorize?: false)
    end

    test "read by process_model_id via identity filter" do
      unique_key = "lookup_#{Ash.UUIDv7.generate()}"

      assert {:ok, created} =
               Process
               |> Ash.Changeset.for_create(:create, %{
                 process_model_id: unique_key,
                 name: "Lookup"
               })
               |> Ash.create(domain: Domain, authorize?: false)

      assert {:ok, [read_back]} =
               Process
               |> Ash.Query.filter(process_model_id == ^unique_key)
               |> Ash.read(domain: Domain, authorize?: false)

      assert read_back.id == created.id
    end
  end

  describe "ProcessVersion and versions relationship" do
    setup do
      {:ok, process} =
        Process
        |> Ash.Changeset.for_create(:create, %{
          process_model_id: "version_parent_#{Ash.UUIDv7.generate()}",
          name: "Parent"
        })
        |> Ash.create(domain: Domain, authorize?: false)

      %{process: process}
    end

    test "create with FK to existing process persists", %{process: process} do
      assert {:ok, version} =
               ProcessVersion
               |> Ash.Changeset.for_create(:create, %{
                 process_id: process.id,
                 version: "1.0.0",
                 bpmn_xml: "<bpmn/>"
               })
               |> Ash.create(domain: Domain, authorize?: false)

      assert version.process_id == process.id
      assert version.version == "1.0.0"
    end

    test "has_many :versions loads correctly", %{process: process} do
      assert {:ok, _} =
               ProcessVersion
               |> Ash.Changeset.for_create(:create, %{
                 process_id: process.id,
                 version: "2.0.0",
                 bpmn_xml: "<bpmn/>"
               })
               |> Ash.create(domain: Domain, authorize?: false)

      assert {:ok, [loaded]} =
               Process
               |> Ash.Query.filter(id == ^process.id)
               |> Ash.Query.load(:versions)
               |> Ash.read(domain: Domain, authorize?: false)

      assert [version_row] = loaded.versions
      assert version_row.version == "2.0.0"
    end

    test "duplicate (process_id, version) returns error", %{process: process} do
      attributes = %{process_id: process.id, version: "3.0.0", bpmn_xml: "<a/>"}

      assert {:ok, _} =
               ProcessVersion
               |> Ash.Changeset.for_create(:create, attributes)
               |> Ash.create(domain: Domain, authorize?: false)

      assert {:error, _} =
               ProcessVersion
               |> Ash.Changeset.for_create(:create, attributes)
               |> Ash.create(domain: Domain, authorize?: false)
    end
  end
end
