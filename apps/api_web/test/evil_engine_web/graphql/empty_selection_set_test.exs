defmodule EvilEngineWeb.Graphql.EmptySelectionSetTest do
  @moduledoc """
  Absinthe rejects empty GraphQL selection sets. The Studio debugger open
  query used to emit `... on TaskNode { }` (and the same for ParallelGateway
  and EventBasedGateway) because those `*Node` types have no extra fields.
  That is a parse error (`syntax error before: '}'`), not a schema gap.
  """
  use ExUnit.Case, async: true

  alias Absinthe.Phase.Parse
  alias EvilEngineWeb.Graphql.Schema

  @empty_task_node_fragment """
  query {
    getProcessInstance(id: "00000000-0000-0000-0000-000000000001") {
      flowNodeInstances {
        flowNode {
          id
          ... on TaskNode {
          }
        }
      }
    }
  }
  """

  @debugger_shaped_without_empty_fragments """
  query($id: ID!) {
    getProcessInstance(id: $id) {
      id
      flowNodeInstances {
        id
        flowNode {
          id
          type
          ... on ServiceTaskNode {
            implementation
          }
        }
      }
    }
  }
  """

  test "an empty inline fragment is a GraphQL syntax error" do
    {:ok, result} = Absinthe.run(@empty_task_node_fragment, Schema)
    messages = error_messages(result)

    assert Enum.any?(messages, &String.contains?(&1, "syntax error")),
           "expected Absinthe parse error for empty `... on TaskNode { }`, got: #{inspect(messages)}"
  end

  test "a debugger-shaped flowNode selection without empty fragments parses" do
    assert {:ok, _blueprint} = Parse.run(@debugger_shaped_without_empty_fragments)
  end

  defp error_messages(result) do
    errors = Map.get(result, :errors) || Map.get(result, "errors") || []

    Enum.map(errors, fn
      %{message: message} -> to_string(message)
      %{"message" => message} -> to_string(message)
      other -> inspect(other)
    end)
  end
end
