defmodule BfwEngine.Api.Validation do
  @moduledoc """
  Shared validation helpers for the `BfwEngine.Api` facade.

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

  @lane_prefix "lane:"

  @doc """
  Classify a lane claim as `:write`, `:read`, or `:none`.

  Only the strings `"write"` and `"read"` grant access. Boolean `true`,
  `"none"`, uppercase variants, and any other value fail closed.
  Accepts an identity struct or a raw claims map.
  """
  @spec lane_access(struct() | map(), String.t()) :: :write | :read | :none
  def lane_access(identity_or_claims, lane_name) when is_binary(lane_name) do
    case Map.get(claims_of(identity_or_claims), @lane_prefix <> lane_name) do
      "write" -> :write
      "read" -> :read
      _ -> :none
    end
  end

  @doc """
  Lane names the caller may observe (`\"read\"` or `\"write\"`).
  """
  @spec accessible_lanes(struct() | map()) :: [String.t()]
  def accessible_lanes(identity_or_claims) do
    identity_or_claims
    |> claims_of()
    |> Enum.filter(fn {key, value} ->
      is_binary(key) and String.starts_with?(key, @lane_prefix) and value in ["read", "write"]
    end)
    |> Enum.map(fn {key, _} -> String.replace_prefix(key, @lane_prefix, "") end)
  end

  @doc """
  Lane names the caller may act on (`\"write\"` only).
  """
  @spec writable_lanes(struct() | map()) :: [String.t()]
  def writable_lanes(identity_or_claims) do
    identity_or_claims
    |> claims_of()
    |> Enum.filter(fn {key, value} ->
      is_binary(key) and String.starts_with?(key, @lane_prefix) and value == "write"
    end)
    |> Enum.map(fn {key, _} -> String.replace_prefix(key, @lane_prefix, "") end)
  end

  @doc """
  Check lane access for a record with a `lane_name` field.

  Write / zeeky / laneless / `skip_claims` → `:ok`.
  Visible but not writable (`\"read\"` on that lane, or `observe_all`) →
  `{:error, :forbidden, %{required_claim, required_value}}` (HTTP 403).
  Invisible → `{:error, :not_found}` (HTTP 404) so existence cannot be probed.
  """
  @spec check_lane_access(struct() | map(), struct() | map(), keyword()) ::
          :ok | {:error, :not_found} | {:error, :forbidden, map()}
  def check_lane_access(record, identity, opts) do
    cond do
      skip_claims?(opts) ->
        :ok

      admin_override?(identity) ->
        :ok

      is_nil(record.lane_name) ->
        :ok

      lane_access(identity, record.lane_name) == :write ->
        :ok

      lane_access(identity, record.lane_name) == :read or observe_all?(identity) ->
        {:error, :forbidden,
         %{required_claim: @lane_prefix <> record.lane_name, required_value: "write"}}

      true ->
        {:error, :not_found}
    end
  end

  @doc "Returns `true` when the identity holds the `zeeky_boogie_doog` admin override claim."
  @spec admin_override?(struct()) :: boolean()
  def admin_override?(identity),
    do: Map.get(claims_of(identity), "zeeky_boogie_doog", false) == true

  @doc "Returns `true` when the identity holds `observe_all=true` (unbounded read, never write)."
  @spec observe_all?(struct() | map()) :: boolean()
  def observe_all?(identity_or_claims),
    do: Map.get(claims_of(identity_or_claims), "observe_all", false) == true

  @doc """
  Returns `true` when the identity may **act** on the named lane (`\"write\"` only).

  A `\"read\"` claim is not enough — use `lane_access/2` when observe vs act matters.
  """
  @spec has_lane_claim?(struct(), String.t()) :: boolean()
  def has_lane_claim?(identity, lane_name),
    do: lane_access(identity, lane_name) == :write

  @spec skip_claims?(keyword()) :: boolean()
  defp skip_claims?(opts), do: Keyword.get(opts, :skip_claims, false)

  defp claims_of(%{claims: claims}) when is_map(claims), do: claims
  defp claims_of(claims) when is_map(claims), do: claims
  defp claims_of(_), do: %{}
end
