defmodule EvilEngine.Api.ValidationTest do
  use ExUnit.Case, async: true

  alias EvilEngine.Api.Validation
  alias EvilEngine.Types.Identity

  defp identity(claims) do
    %Identity{id: "user-1", roles: [], groups: [], claims: claims}
  end

  defp admin_identity do
    identity(%{"zeeky_boogie_doog" => true})
  end

  defp record_with_lane(lane_name), do: %{lane_name: lane_name}

  describe "check_claim/3" do
    test "returns :ok when claim is true" do
      caller_identity = identity(%{"deploy_bpmn" => true})

      assert :ok = Validation.check_claim(caller_identity, "deploy_bpmn", [])
    end

    test "returns forbidden when claim is missing" do
      caller_identity = identity(%{})

      assert {:error, :forbidden, %{required_claim: "deploy_bpmn"}} =
               Validation.check_claim(caller_identity, "deploy_bpmn", [])
    end

    test "returns :ok when skip_claims is true even without claim" do
      caller_identity = identity(%{})

      assert :ok = Validation.check_claim(caller_identity, "deploy_bpmn", skip_claims: true)
    end

    test "returns :ok for admin override even without claim" do
      assert :ok = Validation.check_claim(admin_identity(), "deploy_bpmn", [])
    end

    test "returns forbidden when claim is false" do
      caller_identity = identity(%{"deploy_bpmn" => false})

      assert {:error, :forbidden, %{required_claim: "deploy_bpmn"}} =
               Validation.check_claim(caller_identity, "deploy_bpmn", [])
    end

    test "handles nil claims map gracefully" do
      caller_identity = %Identity{id: "user-1", roles: [], groups: [], claims: nil}

      assert {:error, :forbidden, %{required_claim: "deploy_bpmn"}} =
               Validation.check_claim(caller_identity, "deploy_bpmn", [])

      assert :ok = Validation.check_claim(caller_identity, "deploy_bpmn", skip_claims: true)
    end
  end

  describe "check_scoped_claim/4" do
    test "returns :ok for claim value all" do
      caller_identity = identity(%{"abort_process_instance" => "all"})

      assert :ok =
               Validation.check_scoped_claim(
                 caller_identity,
                 "abort_process_instance",
                 "other-user",
                 []
               )
    end

    test "returns :ok for claim value own when resource owner matches identity id" do
      caller_identity = identity(%{"abort_process_instance" => "own"})

      assert :ok =
               Validation.check_scoped_claim(
                 caller_identity,
                 "abort_process_instance",
                 "user-1",
                 []
               )
    end

    test "returns forbidden for own when owner does not match" do
      caller_identity = identity(%{"abort_process_instance" => "own"})

      assert {:error, :forbidden,
              %{required_claim: "abort_process_instance", required_value: "all"}} =
               Validation.check_scoped_claim(
                 caller_identity,
                 "abort_process_instance",
                 "other-user",
                 []
               )
    end

    test "returns forbidden for none" do
      caller_identity = identity(%{"abort_process_instance" => "none"})

      assert {:error, :forbidden,
              %{required_claim: "abort_process_instance", required_value: "own or all"}} =
               Validation.check_scoped_claim(
                 caller_identity,
                 "abort_process_instance",
                 "user-1",
                 []
               )
    end

    test "returns forbidden when scoped claim is missing" do
      caller_identity = identity(%{})

      assert {:error, :forbidden,
              %{required_claim: "abort_process_instance", required_value: "own or all"}} =
               Validation.check_scoped_claim(
                 caller_identity,
                 "abort_process_instance",
                 "user-1",
                 []
               )
    end

    test "returns :ok for skip_claims" do
      caller_identity = identity(%{})

      assert :ok =
               Validation.check_scoped_claim(
                 caller_identity,
                 "abort_process_instance",
                 "other-user",
                 skip_claims: true
               )
    end

    test "returns :ok for admin override" do
      assert :ok =
               Validation.check_scoped_claim(
                 admin_identity(),
                 "abort_process_instance",
                 "other-user",
                 []
               )
    end
  end

  describe "check_required_claim/4" do
    test "returns :ok when claim matches required value" do
      caller_identity = identity(%{"trigger_message" => "all"})

      assert :ok = Validation.check_required_claim(caller_identity, "trigger_message", "all", [])
    end

    test "returns forbidden when claim does not match required value" do
      caller_identity = identity(%{"trigger_message" => "none"})

      assert {:error, :forbidden,
              %{required_claim: "trigger_message", required_value: "all"}} =
               Validation.check_required_claim(caller_identity, "trigger_message", "all", [])
    end

    test "returns :ok for skip_claims" do
      caller_identity = identity(%{})

      assert :ok =
               Validation.check_required_claim(
                 caller_identity,
                 "trigger_message",
                 "all",
                 skip_claims: true
               )
    end

    test "returns :ok for admin override" do
      assert :ok =
               Validation.check_required_claim(admin_identity(), "trigger_message", "all", [])
    end
  end

  describe "check_lane_access/3" do
    test "returns :ok when lane_name is nil" do
      caller_identity = identity(%{})

      assert :ok = Validation.check_lane_access(record_with_lane(nil), caller_identity, [])
    end

    test "returns :ok when identity has matching lane claim" do
      caller_identity = identity(%{"lane:finance" => true})

      assert :ok =
               Validation.check_lane_access(record_with_lane("finance"), caller_identity, [])
    end

    test "returns not_found when identity lacks lane claim" do
      caller_identity = identity(%{})

      assert {:error, :not_found} =
               Validation.check_lane_access(record_with_lane("finance"), caller_identity, [])
    end

    test "returns :ok for skip_claims" do
      caller_identity = identity(%{})

      assert :ok =
               Validation.check_lane_access(
                 record_with_lane("finance"),
                 caller_identity,
                 skip_claims: true
               )
    end

    test "returns :ok for admin override" do
      assert :ok =
               Validation.check_lane_access(record_with_lane("finance"), admin_identity(), [])
    end
  end

  describe "admin_override?/1" do
    test "returns true when zeeky_boogie_doog claim is true" do
      assert Validation.admin_override?(admin_identity())
    end

    test "returns false when admin claim is missing" do
      refute Validation.admin_override?(identity(%{}))
    end

    test "returns false when admin claim is false" do
      refute Validation.admin_override?(identity(%{"zeeky_boogie_doog" => false}))
    end

    test "returns false when claims map is nil" do
      caller_identity = %Identity{id: "user-1", roles: [], groups: [], claims: nil}
      refute Validation.admin_override?(caller_identity)
    end
  end

  describe "has_lane_claim?/2" do
    test "returns true when lane claim is true" do
      caller_identity = identity(%{"lane:operations" => true})
      assert Validation.has_lane_claim?(caller_identity, "operations")
    end

    test "returns false when lane claim is missing" do
      refute Validation.has_lane_claim?(identity(%{}), "operations")
    end

    test "returns false when lane claim is false" do
      caller_identity = identity(%{"lane:operations" => false})
      refute Validation.has_lane_claim?(caller_identity, "operations")
    end

    test "returns false when claims map is nil" do
      caller_identity = %Identity{id: "user-1", roles: [], groups: [], claims: nil}
      refute Validation.has_lane_claim?(caller_identity, "operations")
    end
  end
end
