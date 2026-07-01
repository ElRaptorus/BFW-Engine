defmodule Examples.Plugins.CustomValidators.Scripts.CurrencyConverter do
  @moduledoc """
  Converts a monetary `amount` from `currency` into EUR using bundled rates.
  """

  @behaviour EvilEngine.Plugin.NamedScript

  @rates_to_eur %{
    "EUR" => 1.0,
    "USD" => 0.92,
    "GBP" => 1.17,
    "CHF" => 1.05
  }

  @doc "Converts a map payload amount from the given currency into EUR using bundled static rates, or errors when values are invalid or the payload is not a map."
  @impl true
  def handle_enter(_flow_node, payload, _context) when is_map(payload) do
    amount = Map.get(payload, "amount")
    currency = Map.get(payload, "currency")

    with {:ok, numeric_amount} <- coerce_amount(amount),
         {:ok, currency_code} <- coerce_currency(currency),
         {:ok, rate} <- rate_for(currency_code) do
      converted_amount = Float.round(numeric_amount * rate, 4)

      {:ok,
       %{
         "original_amount" => numeric_amount,
         "original_currency" => currency_code,
         "converted_amount" => converted_amount,
         "converted_currency" => "EUR"
       }}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle_enter(_flow_node, _payload, _context) do
    {:error, "amount and currency must be present on the payload"}
  end

  defp coerce_amount(amount) when is_integer(amount), do: {:ok, amount * 1.0}

  defp coerce_amount(amount) when is_float(amount), do: {:ok, amount}

  defp coerce_amount(amount) when is_binary(amount) do
    case Float.parse(amount) do
      {float, ""} -> {:ok, float}
      _ -> {:error, "amount must be numeric"}
    end
  end

  defp coerce_amount(_), do: {:error, "amount must be numeric"}

  defp coerce_currency(currency) when is_binary(currency) and currency != "" do
    {:ok, String.upcase(currency)}
  end

  defp coerce_currency(_), do: {:error, "currency must be a non-empty string"}

  defp rate_for(currency_code) do
    case Map.fetch(@rates_to_eur, currency_code) do
      {:ok, rate} -> {:ok, rate}
      :error -> {:error, "unsupported currency: #{currency_code}"}
    end
  end
end
