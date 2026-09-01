defmodule Examples.EventSinks.Sse.ConnectionHub do
  @moduledoc """
  In-memory fan-out of encoded SSE frames to subscriber processes.
  """

  use Agent

  @doc "Starts the named subscriber list Agent."
  def start_link(_opts \\ []) do
    Agent.start_link(fn -> [] end, name: __MODULE__)
  end

  @doc "Ensures the hub Agent is running."
  def ensure_started do
    case Process.whereis(__MODULE__) do
      nil -> start_link()
      _pid -> :ok
    end
  end

  @doc "Registers a subscriber pid to receive `{:sse_event, json, severity}` messages."
  def subscribe(subscriber_pid) when is_pid(subscriber_pid) do
    ensure_started()
    Agent.update(__MODULE__, fn subscribers -> [subscriber_pid | subscribers] end)
  end

  @doc "Removes a subscriber pid from the hub."
  def unsubscribe(subscriber_pid) when is_pid(subscriber_pid) do
    ensure_started()
    Agent.update(__MODULE__, fn subscribers -> List.delete(subscribers, subscriber_pid) end)
  end

  @doc "Sends one encoded event to every live subscriber."
  def broadcast(json_body, severity) when is_binary(json_body) and is_binary(severity) do
    ensure_started()

    subscribers = Agent.get(__MODULE__, & &1)

    Enum.each(subscribers, fn subscriber_pid ->
      if Process.alive?(subscriber_pid) do
        send(subscriber_pid, {:sse_event, json_body, severity})
      end
    end)

    :ok
  end

  @doc "Formats a JSON body as an SSE `data:` frame."
  def frame(json_body) when is_binary(json_body) do
    "data: " <> json_body <> "\n\n"
  end
end
