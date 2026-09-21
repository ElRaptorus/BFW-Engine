defmodule BfwEngine.Test.PayloadCapFixtures do
  @moduledoc """
  Exact-size JSON payload builders for `BFE_TOKEN_MAX_BYTES` tests.

  `mint_payload/1` returns a map whose `Jason.encode!/1` byte size is
  exactly the requested target. Cap tests are meaningless if size is
  approximate.
  """

  @default_limit 65_536

  @doc "Canonical JSON byte size of a term (same measurement as `PayloadCap`). "
  @spec json_byte_size(term()) :: non_neg_integer()
  def json_byte_size(term), do: byte_size(Jason.encode!(term))

  @doc """
  Build `%{"blob" => padding}` whose encoded size is exactly `target_bytes`.

  Padding is ASCII `x` so JSON adds no escape bytes. The envelope
  `{"blob":""}` is 12 bytes; targets at or below that raise.
  """
  @spec mint_payload(pos_integer()) :: map()
  def mint_payload(target_bytes) when is_integer(target_bytes) and target_bytes > 16 do
    envelope_bytes = json_byte_size(%{"blob" => ""})
    padding_length = target_bytes - envelope_bytes

    if padding_length < 0 do
      raise ArgumentError,
            "mint_payload/1 target #{target_bytes} is smaller than the {\"blob\":\"\"} envelope (#{envelope_bytes} bytes)"
    end

    payload = %{"blob" => String.duplicate("x", padding_length)}
    encoded_size = json_byte_size(payload)

    if encoded_size != target_bytes do
      raise ArgumentError,
            "mint_payload/1 could not hit #{target_bytes} bytes (got #{encoded_size})"
    end

    payload
  end

  @doc "Payload whose encoded size is one byte over the default `65_536` cap."
  @spec oversize_payload() :: map()
  def oversize_payload, do: mint_payload(@default_limit + 1)

  @doc "Payload whose encoded size is exactly the default `65_536` cap."
  @spec exactly_at_limit_payload() :: map()
  def exactly_at_limit_payload, do: mint_payload(@default_limit)
end
