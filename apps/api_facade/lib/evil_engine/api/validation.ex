defmodule EvilEngine.Api.Validation do
  @moduledoc """
  Shared validation helpers for the `EvilEngine.Api` facade.

  All claim checks, lane access checks, and admin override logic live
  here so that both REST controllers and plugin facade closures go
  through the same enforcement pipeline. Business rule checks (type,
  state, enabled, active PIs) always apply regardless of `skip_claims`.

  ## `skip_claims` opt-out

  Every function that enforces claims accepts an `opts` keyword list.
  When `Keyword.get(opts, :skip_claims, false)` is `true`, claim checks
  and lane checks are skipped. The plugin loader passes this flag when
  constructing facade closures.

  ## Custom auth provider compatibility

  All helpers read from `identity.claims` — the universal
  `%{String.t() => term()}` map that every auth provider (default JWT
  or custom LDAP/CompanyGraph/Azure) is contractually required to
  populate during `verify_and_resolve/1`.
  """

  @doc "Check a simple boolean claim (e.g. `deploy_bpmn=true`)."
  @spec check_claim(struct(), String.t(), keyword()) :: :ok | {:error, :forbidden, map()}
  def check_claim(identity, claim_name, opts) do
    cond do
      skip_claims?(opts) -> :ok
      admin_override?(identity) -> :ok
      Map.get(identity.claims || %{}, claim_name, false) == true -> :ok
      true -> {:error, :forbidden, %{required_claim: claim_name}}
    end
  end

  @doc """
  Check a scoped claim (`none`/`own`/`all`) with ownership for `own`.

  Returns `:ok` when the caller has `"all"`, or `"own"` and
  `resource_owner_id` matches `identity.id`.
  """
  @spec check_scoped_claim(struct(), String.t(), String.t() | nil, keyword()) ::
          :ok | {:error, :forbidden, map()}
  def check_scoped_claim(identity, claim_name, resource_owner_id, opts) do
    cond do
      skip_claims?(opts) ->
        :ok

      admin_override?(identity) ->
        :ok

      true ->
        evaluate_scoped_claim(identity, claim_name, resource_owner_id)
    end
  end

  defp evaluate_scoped_claim(identity, claim_name, resource_owner_id) do
    claim_value = Map.get(identity.claims || %{}, claim_name, "none")

    case claim_value do
      "all" ->
        :ok

      "own" ->
        if resource_owner_id == identity.id,
          do: :ok,
          else: {:error, :forbidden, %{required_claim: claim_name, required_value: "all"}}

      _ ->
        {:error, :forbidden, %{required_claim: claim_name, required_value: "own or all"}}
    end
  end

  @doc "Check a required-value claim (e.g. `trigger_message=\"all\"`)."
  @spec check_required_claim(struct(), String.t(), String.t(), keyword()) ::
          :ok | {:error, :forbidden, map()}
  def check_required_claim(identity, claim_name, required_value, opts) do
    cond do
      skip_claims?(opts) -> :ok
      admin_override?(identity) -> :ok
      Map.get(identity.claims || %{}, claim_name, "none") == required_value -> :ok
      true -> {:error, :forbidden, %{required_claim: claim_name, required_value: required_value}}
    end
  end

  @doc """
  Check lane access for a record with a `lane_name` field.

  Returns `{:error, :not_found}` (not `:forbidden`) to prevent existence
  probing — invisible lanes behave as if the resource does not exist.
  """
  @spec check_lane_access(struct() | map(), struct() | map(), keyword()) ::
          :ok | {:error, :not_found}
  def check_lane_access(record, identity, opts) do
    cond do
      skip_claims?(opts) -> :ok
      admin_override?(identity) -> :ok
      is_nil(record.lane_name) -> :ok
      has_lane_claim?(identity, record.lane_name) -> :ok
      true -> {:error, :not_found}
    end
  end

  @doc "Returns `true` when the identity holds the `zeeky_boogie_doog` admin override claim."
  @spec admin_override?(struct()) :: boolean()
  def admin_override?(identity),
    do: Map.get(identity.claims || %{}, "zeeky_boogie_doog", false) == true

  @doc "Returns `true` when the identity holds the `lane:<lane_name>` claim."
  @spec has_lane_claim?(struct(), String.t()) :: boolean()
  def has_lane_claim?(identity, lane_name),
    do: Map.get(identity.claims || %{}, "lane:#{lane_name}", false) == true

  @spec skip_claims?(keyword()) :: boolean()
  defp skip_claims?(opts), do: Keyword.get(opts, :skip_claims, false)
end
