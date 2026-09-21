defmodule Examples.Plugins.Adhoc.AiToolbox.AiToolboxPlugin do
  @moduledoc """
  Example plugin that registers the `AiToolboxSink` event sink to drive a
  plugin-managed Ad-hoc Sub-Process (`implementation="ai-toolbox"`).

  Copy this module and `AiToolboxSink` into your own OTP application. See
  `README.md` for the full scenario and the bundled BPMN fixture.
  """

  @behaviour BfwEngine.Plugin

  alias Examples.Plugins.Adhoc.AiToolbox.AiToolboxSink

  @doc "Registers the ai-toolbox event sink, injecting the facade so the sink can drive activation/completion."
  @impl true
  def on_load(facade) do
    facade.register_event_sink.("ai-toolbox", AiToolboxSink, facade: facade)
    :ok
  end

  @doc "Performs no extra work once every plugin has finished loading."
  @impl true
  def on_ready(_facade), do: :ok
end
