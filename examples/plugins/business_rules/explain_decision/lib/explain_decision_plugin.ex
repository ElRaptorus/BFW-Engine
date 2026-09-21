defmodule Examples.BusinessRules.ExplainDecision.ExplainDecisionPlugin do
  @moduledoc """
  Example plugin that registers the `explain_decision` named script handler.

  Script Tasks reference the handler with `<bfw:scriptRef>explain_decision</bfw:scriptRef>`
  after a Business Rule Task has evaluated a DMN decision.
  """

  @behaviour BfwEngine.Plugin

  alias Examples.BusinessRules.ExplainDecision.Script

  @doc "Registers the explain_decision named script on engine load."
  @impl true
  def on_load(engine_facade) do
    engine_facade.register_named_script.("explain_decision", Script)
    :ok
  end

  @doc "Performs no extra work once every plugin has finished loading."
  @impl true
  def on_ready(_engine_facade), do: :ok
end
