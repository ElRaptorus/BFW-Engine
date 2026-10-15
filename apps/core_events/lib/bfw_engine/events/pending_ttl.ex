defmodule BfwEngine.Events.PendingTtl do
  @moduledoc """
  Reads a pending-hold TTL (`BFE_MESSAGE_PENDING_TTL`, `BFE_SIGNAL_PENDING_TTL`)
  from the `:core_events` application environment and converts it to seconds.

  Accepted grammar: `PT<n>S`, `PT<n>M`, or `PT<n>H` with a non-negative integer
  `n`. Any other value logs a warning and falls back to 60 seconds; parsing never
  raises, so a misconfigured TTL cannot lose a publish.
  """

  require Logger

  @fallback_seconds 60

  @doc "Returns the TTL configured under `config_key` in seconds."
  @spec seconds(atom()) :: non_neg_integer()
  def seconds(config_key) do
    value = Application.get_env(:core_events, config_key, "PT60S")

    case parse(value) do
      {:ok, seconds} ->
        seconds

      :error ->
        Logger.warning(
          "Pending TTL #{inspect(config_key)} has unsupported value #{inspect(value)}; " <>
            "expected PT<n>S, PT<n>M, or PT<n>H. Using #{@fallback_seconds} seconds."
        )

        @fallback_seconds
    end
  end

  defp parse(value) when is_binary(value) do
    case Regex.run(~r/\APT(\d+)([SMH])\z/, value) do
      [_, amount, "S"] -> {:ok, String.to_integer(amount)}
      [_, amount, "M"] -> {:ok, String.to_integer(amount) * 60}
      [_, amount, "H"] -> {:ok, String.to_integer(amount) * 3600}
      nil -> :error
    end
  end

  defp parse(_value), do: :error
end
