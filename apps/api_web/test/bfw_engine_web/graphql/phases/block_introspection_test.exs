defmodule BfwEngineWeb.Graphql.Phases.BlockIntrospectionTest do
  use ExUnit.Case, async: true

  alias Absinthe.Blueprint
  alias Absinthe.Blueprint.Document.{Field, Operation}
  alias Absinthe.Blueprint.Document.Fragment.{Inline, Named, Spread}
  alias Absinthe.Phase.Error
  alias BfwEngineWeb.Graphql.Phases.BlockIntrospection

  defp blueprint(operations) do
    %Blueprint{operations: operations, fragments: []}
  end

  defp operation(selections) do
    %Operation{selections: selections, type: :query, name: "Q"}
  end

  defp field(name), do: %Field{name: name, selections: []}

  defp named_fragment(name, selections) do
    %Named{name: name, selections: selections, type_condition: nil}
  end

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

  describe "run/2 — introspection behind fragments" do
    for {label, blueprint_name} <- [
          {"inline fragment with type condition", :typed_inline},
          {"inline fragment without type condition", :untyped_inline},
          {"named fragment spread", :named_spread},
          {"nested fragment spread", :nested_spread},
          {"cyclic fragment spread with __type at the end", :cyclic_spread}
        ] do
      test "#{label} is rejected when disabled" do
        assert {:error, blueprint_with_errors} =
                 run(fragment_blueprint(unquote(blueprint_name)), true)

        assert [%Error{phase: BlockIntrospection, message: "Introspection is disabled."}] =
                 blueprint_with_errors.errors
      end

      test "#{label} passes when introspection is enabled" do
        assert {:ok, _} = run(fragment_blueprint(unquote(blueprint_name)), false)
      end
    end

    test "__typename through an inline fragment is still allowed" do
      inline = %Inline{type_condition: nil, selections: [field("__typename")]}
      assert {:ok, _} = run(blueprint([operation([inline])]), true)
    end

    test "__typename through a named fragment spread is still allowed" do
      named = named_fragment("F", [field("__typename")])
      blueprint = %{blueprint([operation([%Spread{name: "F"}])]) | fragments: [named]}
      assert {:ok, _} = run(blueprint, true)
    end

    test "unknown and cyclic spreads without introspection fields terminate and pass" do
      first = named_fragment("A", [%Spread{name: "B"}, %Spread{name: "Missing"}])
      second = named_fragment("B", [%Spread{name: "A"}])
      blueprint = %{blueprint([operation([%Spread{name: "A"}])]) | fragments: [first, second]}
      assert {:ok, _} = run(blueprint, true)
    end
  end

  defp fragment_blueprint(:typed_inline) do
    inline = %Inline{
      type_condition: %Blueprint.TypeReference.Name{name: "RootQueryType"},
      selections: [field("__schema")]
    }

    blueprint([operation([inline])])
  end

  defp fragment_blueprint(:untyped_inline) do
    inline = %Inline{type_condition: nil, selections: [field("__schema")]}
    blueprint([operation([inline])])
  end

  defp fragment_blueprint(:named_spread) do
    named = named_fragment("F", [field("__type")])
    %{blueprint([operation([%Spread{name: "F"}])]) | fragments: [named]}
  end

  defp fragment_blueprint(:nested_spread) do
    outer =
      named_fragment("Outer", [%Inline{type_condition: nil, selections: [%Spread{name: "Inner"}]}])

    inner = named_fragment("Inner", [field("__schema")])
    %{blueprint([operation([%Spread{name: "Outer"}])]) | fragments: [outer, inner]}
  end

  defp fragment_blueprint(:cyclic_spread) do
    first = named_fragment("A", [%Spread{name: "B"}])
    second = named_fragment("B", [%Spread{name: "A"}, field("__type")])
    %{blueprint([operation([%Spread{name: "A"}])]) | fragments: [first, second]}
  end
end
