defmodule BfwEngineWeb.Graphql.Phases.BlockIntrospectionTest do
  use ExUnit.Case, async: true

  alias Absinthe.Blueprint
  alias Absinthe.Blueprint.Document.{Field, Operation}
  alias Absinthe.Phase.Error
  alias BfwEngineWeb.Graphql.Phases.BlockIntrospection

  defp blueprint(operations) do
    %Blueprint{operations: operations, fragments: []}
  end

  defp operation(selections) do
    %Operation{selections: selections, type: :query, name: "Q"}
  end

  defp field(name), do: %Field{name: name, selections: []}

  defp run(blueprint, disabled?) do
    prev = Application.get_env(:api_web, :graphql_introspection_disabled)
    Application.put_env(:api_web, :graphql_introspection_disabled, disabled?)

    try do
      BlockIntrospection.run(blueprint, [])
    after
      case prev do
        nil -> Application.delete_env(:api_web, :graphql_introspection_disabled)
        v -> Application.put_env(:api_web, :graphql_introspection_disabled, v)
      end
    end
  end

  # ---------------------------------------------------------------------------

  describe "run/2 — introspection enabled (default)" do
    test "__schema passes through when introspection is enabled" do
      bp = blueprint([operation([field("__schema")])])
      assert {:ok, _} = run(bp, false)
    end

    test "__type passes through when introspection is enabled" do
      bp = blueprint([operation([field("__type")])])
      assert {:ok, _} = run(bp, false)
    end

    test "regular field passes through when introspection is enabled" do
      bp = blueprint([operation([field("processes")])])
      assert {:ok, _} = run(bp, false)
    end
  end

  describe "run/2 — introspection disabled" do
    test "__schema is rejected" do
      bp = blueprint([operation([field("__schema")])])
      assert {:error, bp_err} = run(bp, true)
      assert [%Error{phase: BlockIntrospection}] = bp_err.errors
      assert hd(bp_err.errors).message =~ "disabled"
    end

    test "__type is rejected" do
      bp = blueprint([operation([field("__type")])])
      assert {:error, bp_err} = run(bp, true)
      assert [%Error{phase: BlockIntrospection}] = bp_err.errors
    end

    test "regular field passes through even when introspection is disabled" do
      bp = blueprint([operation([field("processInstances")])])
      assert {:ok, _} = run(bp, true)
    end

    test "__typename is NOT blocked (used for type discrimination by clients)" do
      bp = blueprint([operation([field("__typename")])])
      assert {:ok, _} = run(bp, true)
    end

    test "operation mixing regular and __schema fields is rejected" do
      bp = blueprint([operation([field("processes"), field("__schema")])])
      assert {:error, _} = run(bp, true)
    end

    test "empty operation passes through" do
      bp = blueprint([operation([])])
      assert {:ok, _} = run(bp, true)
    end
  end
end
