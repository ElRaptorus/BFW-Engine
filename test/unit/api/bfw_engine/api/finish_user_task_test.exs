defmodule BfwEngine.Api.FinishUserTaskTest do
  use ExUnit.Case, async: false

  alias BfwEngine.Api
  alias BfwEngine.Persistence.ReadRepo
  alias BfwEngine.Persistence.Repo
  alias BfwEngine.Types.Identity
  alias Ecto.Adapters.SQL.Sandbox

  @identity %Identity{id: "finisher", roles: [], groups: []}

  setup do
    :ok = Sandbox.checkout(Repo)
    Sandbox.mode(Repo, {:shared, self()})

    :ok = Sandbox.checkout(ReadRepo)
    Sandbox.mode(ReadRepo, {:shared, self()})

    :ok
  end

  test "rejects values that are not a JSON object" do
    assert {:error, :invalid_values} = Api.finish_user_task("fni-1", "nope", @identity)
    assert {:error, :invalid_values} = Api.finish_user_task("fni-1", [1, 2], @identity)
    assert {:error, :invalid_values} = Api.finish_user_task("fni-1", 4, @identity)
  end

  test "rejects a non-string, blank, or over-long action id" do
    assert {:error, :invalid_action_id} =
             Api.finish_user_task("fni-1", %{}, @identity, action_id: 12)

    assert {:error, :invalid_action_id} =
             Api.finish_user_task("fni-1", %{}, @identity, action_id: "   ")

    assert {:error, :invalid_action_id} =
             Api.finish_user_task("fni-1", %{}, @identity, action_id: String.duplicate("a", 256))
  end

  test "accepts a missing action id far enough to look up the flow node instance" do
    assert {:error, :not_found} =
             Api.finish_user_task("00000000-0000-0000-0000-000000000099", nil, @identity)

    assert {:error, :not_found} =
             Api.finish_user_task("00000000-0000-0000-0000-000000000099", %{}, @identity,
               action_id: nil
             )
  end
end
