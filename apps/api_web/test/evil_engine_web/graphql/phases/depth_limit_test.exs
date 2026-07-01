defmodule EvilEngineWeb.Graphql.Phases.DepthLimitTest do
  use ExUnit.Case, async: true

  alias Absinthe.Blueprint
  alias Absinthe.Blueprint.Document.{Field, Fragment, Operation}
  alias Absinthe.Phase.Error
  alias EvilEngineWeb.Graphql.Phases.DepthLimit

  # ---------------------------------------------------------------------------
  # Helpers to build minimal Blueprint fixtures without running the full
  # Absinthe parse pipeline.
  # ---------------------------------------------------------------------------

  defp blueprint(operations, fragments \\ []) do
    %Blueprint{operations: operations, fragments: fragments}
  end

  defp operation(selections) do
    %Operation{selections: selections, type: :query, name: "TestQuery"}
  end

  defp field(name, children \\ []) do
    %Field{name: name, selections: children}
  end

  defp inline_frag(selections) do
    %Fragment.Inline{
      type_condition: %Absinthe.Blueprint.TypeReference.Name{name: "SomeType"},
      selections: selections
    }
  end

  defp named_frag(name, selections) do
    %Fragment.Named{name: name, type_condition: nil, selections: selections}
  end

  defp spread(name) do
    %Fragment.Spread{name: name}
  end

  defp run(blueprint, max_depth) do
    prev = Application.get_env(:api_web, :graphql_max_depth)
    Application.put_env(:api_web, :graphql_max_depth, max_depth)

    try do
      DepthLimit.run(blueprint, [])
    after
      case prev do
        nil -> Application.delete_env(:api_web, :graphql_max_depth)
        v -> Application.put_env(:api_web, :graphql_max_depth, v)
      end
    end
  end

  # ---------------------------------------------------------------------------

  describe "run/2 — depth within limit" do
    test "empty operation passes" do
      bp = blueprint([operation([])])
      assert {:ok, _} = run(bp, 5)
    end

    test "single top-level field at depth 1 passes" do
      bp = blueprint([operation([field("user")])])
      assert {:ok, _} = run(bp, 5)
    end

    test "nesting exactly at the limit passes" do
      # depth 3: a { b { c } }
      bp = blueprint([operation([field("a", [field("b", [field("c")])])])])
      assert {:ok, _} = run(bp, 3)
    end

    test "inline fragment does not contribute depth" do
      # Inline fragment wrapping one field — effective depth is still 1.
      bp = blueprint([operation([inline_frag([field("city")])])])
      assert {:ok, _} = run(bp, 1)
    end

    test "named fragment spread depth counts through fragment body" do
      frag = named_frag("UserFields", [field("email")])
      # spread at top level: effective depth 1 (the email field inside)
      bp = blueprint([operation([spread("UserFields")])], [frag])
      assert {:ok, _} = run(bp, 1)
    end
  end

  describe "run/2 — depth exceeds limit" do
    test "returns error when nesting exceeds limit" do
      # depth 4: a { b { c { d } } }  — limit 3
      bp =
        blueprint([
          operation([field("a", [field("b", [field("c", [field("d")])])])])
        ])

      assert {:error, bp_err} = run(bp, 3)
      assert [%Error{phase: DepthLimit}] = bp_err.errors
      assert hd(bp_err.errors).message =~ "depth limit of 3"
    end

    test "fragment spread exceeding limit is rejected" do
      frag = named_frag("Deep", [field("a", [field("b", [field("c", [field("d")])])])])
      bp = blueprint([operation([spread("Deep")])], [frag])
      assert {:error, _} = run(bp, 3)
    end

    test "multiple operations: rejects when any exceeds limit" do
      op_shallow = operation([field("x")])
      op_deep = operation([field("a", [field("b", [field("c", [field("d")])])])])
      bp = blueprint([op_shallow, op_deep])
      assert {:error, _} = run(bp, 3)
    end

    test "error message includes the configured max depth" do
      bp = blueprint([operation([field("a", [field("b", [field("c", [field("d")])])])])])
      assert {:error, bp_err} = run(bp, 3)
      assert hd(bp_err.errors).message =~ "3"
    end
  end

  describe "run/2 — fragment cycle guard" do
    test "circular spread reference does not infinite-loop" do
      frag_a = named_frag("A", [spread("B")])
      frag_b = named_frag("B", [spread("A")])
      bp = blueprint([operation([spread("A")])], [frag_a, frag_b])
      assert {:ok, _} = run(bp, 100)
    end
  end
end
