defmodule BfwEngine.Persistence.Calculations.FinalTokens do
  @moduledoc """
  Ash calculation that derives `finalTokens` for a finished ProcessInstance.

  For PIs with `state = "finished"`: queries `flow_node_instances` where
  `flow_node_type = "end_event"` and `state = "finished"`, returning a list
  of maps with `endEventId`, `endEventName`, and `payload` from each
  FNI's persisted data (camelCase ). The `endEventName` is read from
  `type_properties["end_event_name"]`, which the EndEvent handler stores at
  dispatch time.

  For PIs in any other state: returns `nil`.

  Batches queries by collecting all PI IDs in a single read to avoid N+1.
  See data-model.md §4.2, api.md §10.2.1.1 for the design
  rationale: no `final_token` column exists — the value is always derived
  from End-Event FNIs.

  **Call Activity contract:** the Call Activity `onFinished` handler reads
  `output_token` from the terminating End-Event FNI(s) of the child PI —
  the same data source this calculation uses. The contract is identical:
  End-Event FNIs own the terminal payload.
  """

  use Ash.Resource.Calculation

  alias BfwEngine.Persistence.Resources.FlowNodeInstance

  require Ash.Query

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def load(_query, _opts, _context), do: [:id, :state]

  @impl true
  def calculate(records, _opts, _context) do
    finished_process_instance_ids =
      records
      |> Enum.filter(&(&1.state == "finished"))
      |> Enum.map(& &1.id)

    flow_node_instances_by_process_instance_id =
      if finished_process_instance_ids == [] do
        %{}
      else
        FlowNodeInstance
        |> Ash.Query.filter(
          process_instance_id in ^finished_process_instance_ids and
            flow_node_type == "end_event" and
            state == "finished"
        )
        |> Ash.Query.select([
          :id,
          :process_instance_id,
          :flow_node_id,
          :output_token,
          :type_properties
        ])
        |> Ash.read!(authorize?: false)
        |> Enum.group_by(& &1.process_instance_id)
      end

    Enum.map(records, &tokens_for_record(&1, flow_node_instances_by_process_instance_id))
  end

  defp tokens_for_record(%{state: "finished", id: id}, flow_node_instances_by_process_instance_id) do
    flow_node_instances_by_process_instance_id
    |> Map.get(id, [])
    |> Enum.map(&flow_node_instance_to_token/1)
  end

  defp tokens_for_record(_record, _flow_node_instances_by_process_instance_id), do: nil

  defp flow_node_instance_to_token(flow_node_instance) do
    end_event_name =
      case flow_node_instance.type_properties do
        %{"end_event_name" => name} -> name
        _ -> nil
      end

    %{
      "endEventId" => flow_node_instance.flow_node_id,
      "endEventName" => end_event_name,
      "payload" => flow_node_instance.output_token
    }
  end
end
