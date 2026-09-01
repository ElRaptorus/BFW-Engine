defmodule Examples.BusinessRules.DecisionAuditReporter.EventTracker do
  @moduledoc """
  Agent-backed set of Business Rule Task flow node instance IDs observed during
  the collection window.

  The sink writes IDs here; `FniInspector` later re-reads each FNI through the
  facade so the audit report uses persisted `type_properties`, not the live event.
  """

  use Agent

  @default_name __MODULE__

  @type tracked_event :: %{
          flow_node_instance_id: String.t(),
          process_instance_id: String.t() | nil,
          flow_node_id: String.t() | nil
        }

  @doc "Starts the tracker agent. Options: `:name` (default `EventTracker`)."
  def start_link(options \\ []) do
    agent_name = Keyword.get(options, :name, @default_name)
    Agent.start_link(fn -> %{} end, name: agent_name)
  end

  @doc "Records one DMN Business Rule Task completion by flow node instance ID."
  @spec track(tracked_event(), keyword()) :: :ok
  def track(tracked_event, options \\ []) do
    agent_name = Keyword.get(options, :name, @default_name)
    flow_node_instance_id = tracked_event.flow_node_instance_id

    Agent.update(agent_name, fn events ->
      Map.put(events, flow_node_instance_id, tracked_event)
    end)
  end

  @doc "Returns tracked flow node instance IDs in insertion order."
  @spec get_tracked_flow_node_instance_ids(keyword()) :: [String.t()]
  def get_tracked_flow_node_instance_ids(options \\ []) do
    agent_name = Keyword.get(options, :name, @default_name)
    Agent.get(agent_name, fn events -> Map.keys(events) end)
  end

  @doc "Returns the number of tracked flow node instances."
  @spec get_count(keyword()) :: non_neg_integer()
  def get_count(options \\ []) do
    agent_name = Keyword.get(options, :name, @default_name)
    Agent.get(agent_name, &map_size/1)
  end

  @doc "Returns the tracked event maps."
  @spec get_events(keyword()) :: [tracked_event()]
  def get_events(options \\ []) do
    agent_name = Keyword.get(options, :name, @default_name)
    Agent.get(agent_name, &Map.values/1)
  end

  @doc "Clears all tracked flow node instances."
  @spec reset(keyword()) :: :ok
  def reset(options \\ []) do
    agent_name = Keyword.get(options, :name, @default_name)
    Agent.update(agent_name, fn _events -> %{} end)
  end
end
