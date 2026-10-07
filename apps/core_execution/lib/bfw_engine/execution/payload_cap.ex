defmodule BfwEngine.Execution.PayloadCap do
  @moduledoc """
  Core-domain guard enforcing the `BFE_TOKEN_MAX_BYTES` hard payload cap.

  This is the **authoritative enforcement site** — every payload-producing
  operation in the engine must go through `check/2` before persisting. The
  process instance calls it on token output, message and signal publish,
  and any FEEL-originated payload. The escalation
  REST trigger (`POST /escalations/{escalation_code}/trigger`) carries no
  payload and does not call PayloadCap. The API layer calls it as a
  supplementary fast-fail on inbound request bodies that do carry a payload.

  The function is pure — callers decide the consequence of a violation
  (FNI -> fatal, HTTP -> 413, GraphQL -> typed error).
  """

  @min_cap_bytes 1024
  @default_cap_bytes 65_536

  @doc """
  Checks whether `payload` fits within `BFE_TOKEN_MAX_BYTES`.

  Returns `:ok` when the canonicalized JSON byte size is within the limit.
  Returns `{:error, :payload_too_large, details}` when it exceeds the cap.

  ## Options

    * `:field` — a descriptive atom identifying the payload origin
      (e.g. `:fni_output`, `:message_payload`). Defaults to `:payload`.

  ## Examples

      iex> PayloadCap.check(%{key: "value"})
      :ok

      iex> PayloadCap.check(String.duplicate("x", 100_000))
      {:error, :payload_too_large, %{size: 100002, limit: 65536, field: :payload}}
  """
  @spec check(term(), keyword()) :: :ok | {:error, :payload_too_large, map()}
  def check(payload, opts \\ [])

  def check(nil, _opts), do: :ok

  def check(payload, opts) do
    field = Keyword.get(opts, :field, :payload)
    limit = resolve_limit()

    with {:ok, json_bytes} <- measure(payload) do
      if json_bytes <= limit do
        :ok
      else
        {:error, :payload_too_large, %{size: json_bytes, limit: limit, field: field}}
      end
    end
  end

  defp measure(payload) do
    case Jason.encode(payload) do
      {:ok, encoded} -> {:ok, byte_size(encoded)}
      {:error, reason} -> {:error, :encode_failed, %{reason: reason}}
    end
  end

  defp resolve_limit do
    cap = Application.get_env(:core_execution, :token_max_bytes, @default_cap_bytes)
    max(cap, @min_cap_bytes)
  end

  @doc """
  Parse `BFE_TOKEN_MAX_BYTES` at boot.

  Unset or blank → `#{@default_cap_bytes}`. An explicit integer below
  `#{@min_cap_bytes}` raises (does **not** clamp). The error message
  includes `minimum_required: #{@min_cap_bytes}`.
  """
  @spec parse_token_max_bytes(String.t() | integer() | nil, pos_integer()) :: pos_integer()
  def parse_token_max_bytes(raw, default \\ @default_cap_bytes)

  def parse_token_max_bytes(nil, default), do: default
  def parse_token_max_bytes("", default), do: default

  def parse_token_max_bytes(raw, default) when is_binary(raw) do
    parse_token_max_bytes(String.to_integer(String.trim(raw)), default)
  end

  def parse_token_max_bytes(value, _default)
      when is_integer(value) and value < @min_cap_bytes do
    raise "BFE_TOKEN_MAX_BYTES must be >= #{@min_cap_bytes} (minimum_required: #{@min_cap_bytes}), got #{value}"
  end

  def parse_token_max_bytes(value, _default) when is_integer(value) and value >= @min_cap_bytes do
    value
  end
end
