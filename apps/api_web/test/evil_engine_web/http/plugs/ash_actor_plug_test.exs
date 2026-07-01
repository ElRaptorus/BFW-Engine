defmodule EvilEngineWeb.Http.Plugs.AshActorPlugTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias EvilEngine.Types.Identity
  alias EvilEngineWeb.Http.Plugs.AshActorPlug

  describe "init/1" do
    test "returns opts unchanged" do
      assert AshActorPlug.init([]) == []
      assert AshActorPlug.init(foo: :bar) == [foo: :bar]
    end
  end

  describe "call/2 — no identity on conn" do
    test "returns conn unchanged when no identity assigned" do
      conn = %Plug.Conn{assigns: %{}}
      result = AshActorPlug.call(conn, [])
      assert result == conn
      assert Ash.PlugHelpers.get_actor(result) == nil
    end
  end

  describe "call/2 — identity present" do
    test "sets Ash actor on conn.private from identity" do
      identity = %Identity{
        id: "user-42",
        roles: ["operator"],
        groups: [],
        claims: %{
          "deploy_bpmn" => true,
          "delete_bpmn" => false,
          "zeeky_boogie_doog" => false
        }
      }

      conn = %Plug.Conn{assigns: %{identity: identity}}
      result = AshActorPlug.call(conn, [])

      actor = Ash.PlugHelpers.get_actor(result)
      assert actor.id == "user-42"
      assert actor.deploy_bpmn == true
      assert actor.delete_bpmn == false
      assert actor.zeeky_boogie_doog == false
      assert is_list(actor.accessible_lanes)
    end

    test "extracts lane names from claims into accessible_lanes" do
      identity = %Identity{
        id: "user-99",
        roles: [],
        groups: [],
        claims: %{
          "lane:finance" => true,
          "lane:ops" => true,
          "lane:disabled" => false,
          "deploy_bpmn" => false
        }
      }

      conn = %Plug.Conn{assigns: %{identity: identity}}
      result = AshActorPlug.call(conn, [])

      actor = Ash.PlugHelpers.get_actor(result)
      assert "finance" in actor.accessible_lanes
      assert "ops" in actor.accessible_lanes
      refute "disabled" in actor.accessible_lanes
    end

    test "coerces missing claim keys to false" do
      identity = %Identity{id: "user-1", roles: [], groups: [], claims: %{}}

      conn = %Plug.Conn{assigns: %{identity: identity}}
      result = AshActorPlug.call(conn, [])

      actor = Ash.PlugHelpers.get_actor(result)
      assert actor.deploy_bpmn == false
      assert actor.delete_bpmn == false
      assert actor.zeeky_boogie_doog == false
    end

    test "returns a modified conn with the actor stored in private" do
      identity = %Identity{id: "user-2", roles: [], groups: [], claims: %{}}

      conn = %Plug.Conn{assigns: %{identity: identity}}
      original_private = conn.private

      result = AshActorPlug.call(conn, [])

      assert result.private != original_private
      assert result.assigns == conn.assigns
    end
  end
end
