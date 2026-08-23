defmodule EvilEngine.Persistence.DataObjectPolicyTest do
  @moduledoc """
  Policy tests for DataObject and DataObjectWrite Ash resources.
  Verifies PI-visibility scoping: only data objects belonging to PIs the
  actor started or has lane access to are returned. ZeekyBoogieDoog
  bypasses all checks.
  """
  use ExUnit.Case, async: false

  alias EvilEngine.Persistence.Api, as: Domain
  alias EvilEngine.Persistence.Resources.DataObject, as: DataObjectResource
  alias EvilEngine.Persistence.Resources.DataObjectWrite

  alias Ecto.Adapters.SQL.Sandbox
  alias EvilEngine.Persistence.Repo

  setup do
    Sandbox.checkout(Repo, ownership_timeout: 60_000)
    Sandbox.mode(Repo, {:shared, self()})

    :ok
  end

  describe "DataObject read policies" do
    test "read with valid actor returns only PI-visible records (empty DB returns empty)" do
      actor = %{id: "test-user", accessible_lanes: ["default"]}

      result =
        DataObjectResource
        |> Ash.Query.limit(10)
        |> Ash.read(domain: Domain, actor: actor)

      assert {:ok, []} = result
    end

    test "read without actor returns empty results (fail closed)" do
      result =
        DataObjectResource
        |> Ash.Query.limit(10)
        |> Ash.read(domain: Domain, actor: nil)

      assert {:ok, []} = result
    end

    test "ZeekyBoogieDoog bypass allows full access" do
      actor = %{zeeky_boogie_doog: true}

      result =
        DataObjectResource
        |> Ash.Query.limit(10)
        |> Ash.read(domain: Domain, actor: actor)

      assert {:ok, _records} = result
    end

    test "ObserveAll bypass allows read access" do
      actor = %{observe_all: true, accessible_lanes: []}

      result =
        DataObjectResource
        |> Ash.Query.limit(10)
        |> Ash.read(domain: Domain, actor: actor)

      assert {:ok, _records} = result
    end
  end

  describe "DataObjectWrite read policies" do
    test "read with valid actor returns only PI-visible records (empty DB returns empty)" do
      actor = %{id: "test-user", accessible_lanes: ["default"]}

      result =
        DataObjectWrite
        |> Ash.Query.limit(10)
        |> Ash.read(domain: Domain, actor: actor)

      assert {:ok, []} = result
    end

    test "read without actor returns empty results (fail closed)" do
      result =
        DataObjectWrite
        |> Ash.Query.limit(10)
        |> Ash.read(domain: Domain, actor: nil)

      assert {:ok, []} = result
    end

    test "ZeekyBoogieDoog bypass allows full access" do
      actor = %{zeeky_boogie_doog: true}

      result =
        DataObjectWrite
        |> Ash.Query.limit(10)
        |> Ash.read(domain: Domain, actor: actor)

      assert {:ok, _records} = result
    end
  end
end
