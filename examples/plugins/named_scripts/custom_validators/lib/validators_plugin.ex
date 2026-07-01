defmodule Examples.Plugins.CustomValidators.ValidatorsPlugin do
  @moduledoc """
  Registers multiple `EvilEngine.Plugin.NamedScript` handlers under one umbrella plugin.
  """

  @behaviour EvilEngine.Plugin

  alias Examples.Plugins.CustomValidators.Scripts.{
    CurrencyConverter,
    IdempotencyGuard,
    PayloadValidator
  }

  @doc "Registers the validate_payload, convert_currency, and idempotency_guard named scripts with error propagation."
  @impl true
  def on_load(facade) do
    with :ok <- register_or_fail(facade, "validate_payload", PayloadValidator),
         :ok <- register_or_fail(facade, "convert_currency", CurrencyConverter),
         :ok <- register_or_fail(facade, "idempotency_guard", IdempotencyGuard) do
      :ok
    end
  end

  @doc "Performs no extra work once every plugin has finished loading."
  @impl true
  def on_ready(_facade), do: :ok

  defp register_or_fail(facade, script_key, module) do
    case facade.register_named_script.(script_key, module) do
      :ok -> :ok
      {:error, reason} -> {:error, {:named_script_registration_failed, script_key, reason}}
    end
  end
end
