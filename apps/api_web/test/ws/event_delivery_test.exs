defmodule BfwEngineWeb.Ws.EventDeliveryTest do
  use ExUnit.Case, async: true

  alias BfwEngine.Types.Wire
  alias BfwEngineWeb.Ws.EventDelivery

  defp assigns(overrides) do
    Map.merge(
      %{
        admin_override: false,
        observe_all: false,
        accessible_lanes: [],
        identity_id: "user-1",
        topic: "engine:events"
      },
      overrides
    )
  end

  defp envelope(type, data \\ %{}) do
    %{"type" => type, "data" => data, "occurredAt" => "2026-08-22T12:00:00Z"}
  end

  describe "observe_all" do
    test "delivers every event type on every topic without a lane claim" do
      observer = assigns(%{observe_all: true, accessible_lanes: [], identity_id: "observer"})

      assert EventDelivery.should_deliver?(
               envelope("FlowNodeInstanceStarted", %{"laneName" => "Management"}),
               observer
             )

      assert EventDelivery.should_deliver?(
               envelope("ProcessInstanceStateChanged", %{
                 "startedById" => "someone-else",
                 "hasLanelessFlowNode" => false,
                 "laneNames" => ["Management"]
               }),
               observer
             )

      assert EventDelivery.should_deliver?(
               envelope("UnknownEnvelopeType", %{"laneName" => "Management"}),
               observer
             )
    end
  end

  describe "admin_override" do
    test "delivers every event type on every topic" do
      admin = assigns(%{admin_override: true, accessible_lanes: [], identity_id: "admin"})

      assert EventDelivery.should_deliver?(
               envelope("FlowNodeInstanceStarted", %{"laneName" => "Management"}),
               admin
             )

      assert EventDelivery.should_deliver?(
               envelope("ProcessInstanceStateChanged", %{
                 "startedById" => "someone-else",
                 "hasLanelessFlowNode" => false,
                 "laneNames" => ["Management"]
               }),
               admin
             )

      assert EventDelivery.should_deliver?(
               envelope("EngineStarted", %{"engineId" => "e1"}),
               Map.put(admin, :topic, "user_tasks:pending")
             )
    end
  end

  describe "engine-level events" do
    test "always deliver on engine:events without a lane claim" do
      subscriber = assigns(%{})

      for type <- EventDelivery.classified_types().engine_level do
        assert EventDelivery.should_deliver?(envelope(type), subscriber),
               "#{type} should always be delivered"
      end
    end
  end

  describe "flow-node-originating events" do
    test "delivers laneless FNIs for every originating type" do
      subscriber = assigns(%{accessible_lanes: []})

      for type <- EventDelivery.classified_types().flow_node_originating do
        assert EventDelivery.should_deliver?(
                 envelope(type, %{"laneName" => nil}),
                 subscriber
               ),
               "#{type} with laneName nil must be delivered"
      end
    end

    test "drops Management FNI for every originating type when the subscriber has no matching lane" do
      subscriber = assigns(%{accessible_lanes: []})

      for type <- EventDelivery.classified_types().flow_node_originating do
        refute EventDelivery.should_deliver?(
                 envelope(type, %{"laneName" => "Management"}),
                 subscriber
               ),
               "#{type} with laneName Management must be dropped"
      end
    end

    test "delivers Management FNI for every originating type when the subscriber has the matching lane" do
      subscriber = assigns(%{accessible_lanes: ["Management"]})

      for type <- EventDelivery.classified_types().flow_node_originating do
        assert EventDelivery.should_deliver?(
                 envelope(type, %{"laneName" => "Management"}),
                 subscriber
               ),
               "#{type} with a matching Management claim must be delivered"
      end
    end

    test "applies the same lane rule on process_instance topics" do
      subscriber =
        assigns(%{topic: "process_instance:pi-1", accessible_lanes: []})

      for type <- EventDelivery.classified_types().flow_node_originating do
        refute EventDelivery.should_deliver?(
                 envelope(type, %{"laneName" => "Management"}),
                 subscriber
               ),
               "#{type} must be lane-gated on process_instance topics"
      end
    end

    test "Jason-encoded FNI structs stamp laneName and are gated" do
      subscriber = assigns(%{accessible_lanes: []})
      matching = assigns(%{accessible_lanes: ["Management"]})

      for type <- EventDelivery.classified_types().flow_node_originating do
        module = Module.concat(BfwEngine.Types.Event, type)
        event = struct(module, lane_name: "Management")

        payload = %{
          "type" => type,
          "data" => Wire.struct_to_camel_map(event),
          "occurredAt" => DateTime.utc_now()
        }

        assert payload["data"]["laneName"] == "Management",
               "#{type} JSON must include laneName"

        refute EventDelivery.should_deliver?(payload, subscriber),
               "#{type} encoded with Management must be dropped"

        assert EventDelivery.should_deliver?(payload, matching),
               "#{type} encoded with Management must be delivered to a matching lane"
      end
    end
  end

  describe "unknown envelope types" do
    test "are dropped even when laneName is nil" do
      subscriber = assigns(%{accessible_lanes: []})

      refute EventDelivery.should_deliver?(
               envelope("NotARealEngineEvent", %{"laneName" => nil}),
               subscriber
             )
    end

    test "are still delivered under admin_override" do
      admin = assigns(%{admin_override: true, accessible_lanes: []})

      assert EventDelivery.should_deliver?(
               envelope("NotARealEngineEvent", %{"laneName" => "Management"}),
               admin
             )
    end
  end

  describe "classified_types/0" do
    test "covers every EngineEventBus event module except SinkFailed" do
      classified = EventDelivery.classified_types()

      listed =
        (classified.engine_level ++
           classified.process_instance_level ++ classified.flow_node_originating)
        |> MapSet.new()

      overlaps =
        MapSet.intersection(
          MapSet.new(classified.engine_level),
          MapSet.new(classified.flow_node_originating)
        )

      assert MapSet.size(overlaps) == 0

      event_module_types =
        :core_types
        |> load_application_modules()
        |> Enum.map(&Module.split/1)
        |> Enum.filter(fn parts ->
          match?(["BfwEngine", "Types", "Event", _name], parts)
        end)
        |> Enum.map(&List.last/1)
        |> Enum.reject(&(&1 == "SinkFailed"))
        |> MapSet.new()

      missing = MapSet.difference(event_module_types, listed)
      extra = MapSet.difference(listed, event_module_types)

      assert missing == MapSet.new(),
             "EventDelivery allow-lists are missing #{inspect(MapSet.to_list(missing))}"

      assert extra == MapSet.new(),
             "EventDelivery allow-lists contain unknown types #{inspect(MapSet.to_list(extra))}"
    end
  end

  describe "process-instance-level events on process_instance:*" do
    test "always deliver after a successful join" do
      subscriber =
        assigns(%{
          topic: "process_instance:pi-1",
          identity_id: "starter-user",
          accessible_lanes: []
        })

      assert EventDelivery.should_deliver?(
               envelope("ProcessInstanceStateChanged", %{
                 "startedById" => "someone-else",
                 "hasLanelessFlowNode" => false,
                 "laneNames" => ["Management"]
               }),
               subscriber
             )

      assert EventDelivery.should_deliver?(
               envelope("ProcessInstanceRetried", %{
                 "startedById" => "someone-else",
                 "hasLanelessFlowNode" => false,
                 "laneNames" => []
               }),
               subscriber
             )
    end
  end

  describe "process-instance-level events on engine:events" do
    test "delivers to the starter even without a lane claim" do
      subscriber = assigns(%{identity_id: "starter-user", accessible_lanes: []})

      assert EventDelivery.should_deliver?(
               envelope("ProcessInstanceStateChanged", %{
                 "startedById" => "starter-user",
                 "hasLanelessFlowNode" => false,
                 "laneNames" => ["Management"]
               }),
               subscriber
             )
    end

    test "drops for a stranger with no matching lane and no laneless FNI" do
      subscriber = assigns(%{identity_id: "stranger", accessible_lanes: []})

      refute EventDelivery.should_deliver?(
               envelope("ProcessInstanceStateChanged", %{
                 "startedById" => "starter-user",
                 "hasLanelessFlowNode" => false,
                 "laneNames" => ["Management"]
               }),
               subscriber
             )
    end

    test "delivers to a stranger who holds a matching lane" do
      subscriber = assigns(%{identity_id: "stranger", accessible_lanes: ["Management"]})

      assert EventDelivery.should_deliver?(
               envelope("ProcessInstanceStateChanged", %{
                 "startedById" => "starter-user",
                 "hasLanelessFlowNode" => false,
                 "laneNames" => ["Management"]
               }),
               subscriber
             )
    end

    test "delivers when the PI has a laneless flow node" do
      subscriber = assigns(%{identity_id: "stranger", accessible_lanes: []})

      assert EventDelivery.should_deliver?(
               envelope("ProcessInstanceStateChanged", %{
                 "startedById" => "starter-user",
                 "hasLanelessFlowNode" => true,
                 "laneNames" => ["Management"]
               }),
               subscriber
             )
    end
  end

  describe "user_tasks:pending" do
    test "delivers UserTaskCreated when the lane is accessible" do
      subscriber =
        assigns(%{topic: "user_tasks:pending", accessible_lanes: ["Management"]})

      assert EventDelivery.should_deliver?(
               envelope("UserTaskCreated", %{"laneName" => "Management"}),
               subscriber
             )
    end

    test "drops UserTaskCreated when the lane is inaccessible" do
      subscriber = assigns(%{topic: "user_tasks:pending", accessible_lanes: []})

      refute EventDelivery.should_deliver?(
               envelope("UserTaskCreated", %{"laneName" => "Management"}),
               subscriber
             )
    end

    test "drops event types that are not pending-task envelopes" do
      subscriber = assigns(%{topic: "user_tasks:pending", accessible_lanes: ["Management"]})

      refute EventDelivery.should_deliver?(
               envelope("FlowNodeInstanceStarted", %{"laneName" => "Management"}),
               subscriber
             )

      refute EventDelivery.should_deliver?(envelope("EngineStarted"), subscriber)
    end
  end

  defp load_application_modules(application) do
    case Application.spec(application, :modules) do
      modules when is_list(modules) ->
        modules

      _missing ->
        _ = Application.load(application)
        Application.spec(application, :modules) || []
    end
  end
end
