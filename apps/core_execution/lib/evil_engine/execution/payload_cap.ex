defmodule EvilEngine.Execution.PayloadCap do
  @moduledoc """
  Core-domain guard enforcing the `TDE_TOKEN_MAX_BYTES` hard payload cap.

  This is the **authoritative enforcement site** — every payload-producing
  operation in the engine must go through `check/2` before persisting. The
  PI Facade (Phase 1) calls it on `write_result/2`, `publish_message/2`,
  `publish_signal/2`, and any FEEL-originated token output. The escalation
  REST trigger (`POST /escalations/{escalation_code}/trigger`) carries no
  payload and does not call PayloadCap. The API layer calls it as a
  supplementary fast-fail on inbound request bodies that do carry a payload.

  The function is pure — callers decide the consequence of a violation
  (FNI -> fatal, HTTP -> 413, GraphQL -> typed error).
  """

  @min_cap_bytes 1024

  @doc """
  Checks whether `payload` fits within `TDE_TOKEN_MAX_BYTES`.

  Returns `:ok` when the canonicalized JSON byte size is within the limit.
  Returns `{:error, :payload_too_large, details}` when it exceeds the cap.

  ## Options

    * `:field` — a descriptive atom identifying the payload origin
      (e.g. `:fni_output`, `:message_payload`). Defaults to `:payload`.
    * `:limit` — override the configured cap (useful for testing).
      Must be >= #{@min_cap_bytes}.

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
    limit = resolve_limit(opts)

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

  defp resolve_limit(opts) do
    explicit = Keyword.get(opts, :limit)

    cap =
      if is_integer(explicit) do
        explicit
      else
        Application.get_env(:core_execution, :token_max_bytes, 65_536)
      end

    max(cap, @min_cap_bytes)
  end
end
