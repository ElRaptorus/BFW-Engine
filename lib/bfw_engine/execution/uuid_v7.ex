defmodule BfwEngine.Execution.UuidV7 do
  @moduledoc """
  Time-ordered UUID version 7 values for process and flow-node instance ids.
  """

  @doc "Generates a version 7 UUID (time-ordered, random tail)."
  @spec generate() :: String.t()
  def generate do
    timestamp_ms = System.system_time(:millisecond)
    <<rand_a::12, rand_b::62, _::6>> = :crypto.strong_rand_bytes(10)

    <<timestamp_ms::48, 7::4, rand_a::12, 2::2, rand_b::62>>
    |> Base.encode16(case: :lower)
    |> then(fn <<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>> ->
      "#{a}-#{b}-#{c}-#{d}-#{e}"
    end)
  end
end
