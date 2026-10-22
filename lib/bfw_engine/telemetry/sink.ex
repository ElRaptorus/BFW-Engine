defmodule BfwEngine.Telemetry.Sink do
  @moduledoc """
  Telemetry counter sink. Default ON.

  Increments in-process `:telemetry` counters on every event.
  These counters back the `/stats` endpoint. O(1) per event.
  """

  @behaviour BfwEngine.Plugin.EventSink

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def accepts?(_event), do: true

  @impl true
  def handle_event(event, state) do
    event_type = event_type_atom(event)

    :telemetry.execute(
      [:bfw_engine, :event_bus],
      %{count: 1},
      %{event_type: event_type, event: event}
    )

    {:ok, state}
  end

  @impl true
  def handle_shutdown(_state), do: :ok

  defp event_type_atom(event) do
    event.__struct__
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.to_atom()
  end
end
