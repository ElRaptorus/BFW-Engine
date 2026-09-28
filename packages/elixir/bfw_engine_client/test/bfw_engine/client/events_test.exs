defmodule BfwEngine.Client.EventsTest do
  use ExUnit.Case, async: true

  alias BfwEngine.Client
  alias BfwEngine.Client.Error
  alias BfwEngine.Client.Events

  setup do
    stub_name = {__MODULE__, System.unique_integer()}

    client =
      Client.new(base_url: "http://engine.invalid", req_options: [plug: {Req.Test, stub_name}])

    {:ok, stub_name: stub_name, client: client}
  end

  describe "trigger_message/3" do
    test "POSTs the message endpoint with a correlation key (not correlationValue)", %{
      stub_name: stub_name,
      client: client
    } do
      Req.Test.stub(stub_name, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/messages/order-paid/trigger"
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw_body)
        assert body == %{"payload" => %{"amount" => 10}, "correlation" => "order-1"}
        refute Map.has_key?(body, "correlationValue")
        Req.Test.json(conn, %{"deliveries" => []})
      end)

      assert {:ok, %{"deliveries" => []}} =
               Events.trigger_message(client, "order-paid",
                 payload: %{"amount" => 10},
                 correlation: "order-1"
               )
    end

    test "maps a not-found error", %{stub_name: stub_name, client: client} do
      Req.Test.stub(stub_name, fn conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"error" => "not_found"})
      end)

      assert {:error, %Error{reason: :not_found}} = Events.trigger_message(client, "unknown")
    end

    test "encodes a slash in the message name", %{stub_name: stub_name, client: client} do
      Req.Test.stub(stub_name, fn conn ->
        assert conn.request_path == "/messages/a%2Fb/trigger"
        Req.Test.json(conn, %{"deliveries" => []})
      end)

      assert {:ok, %{"deliveries" => []}} = Events.trigger_message(client, "a/b")
    end
  end

  describe "trigger_signal/2" do
    test "POSTs an empty body to the signal endpoint", %{stub_name: stub_name, client: client} do
      Req.Test.stub(stub_name, fn conn ->
        assert conn.request_path == "/signals/order-cancelled/trigger"
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw_body) == %{}
        Req.Test.json(conn, %{"deliveries" => []})
      end)

      assert {:ok, %{"deliveries" => []}} = Events.trigger_signal(client, "order-cancelled")
    end
  end

  describe "trigger_escalation/2" do
    test "POSTs an empty body to the escalation endpoint", %{
      stub_name: stub_name,
      client: client
    } do
      Req.Test.stub(stub_name, fn conn ->
        assert conn.request_path == "/escalations/slow-response/trigger"
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw_body) == %{}
        Req.Test.json(conn, %{"deliveries" => []})
      end)

      assert {:ok, %{"deliveries" => []}} = Events.trigger_escalation(client, "slow-response")
    end

    test "maps a forbidden error", %{stub_name: stub_name, client: client} do
      Req.Test.stub(stub_name, fn conn ->
        conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"error" => "forbidden"})
      end)

      assert {:error, %Error{reason: :forbidden}} =
               Events.trigger_escalation(client, "slow-response")
    end
  end

  describe "trigger_timer/2" do
    test "POSTs an empty body to the timer endpoint", %{stub_name: stub_name, client: client} do
      Req.Test.stub(stub_name, fn conn ->
        assert conn.request_path == "/timer-events/fni-1/trigger"
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw_body) == %{}
        Req.Test.json(conn, %{"triggered" => true})
      end)

      assert {:ok, %{"triggered" => true}} = Events.trigger_timer(client, "fni-1")
    end

    test "maps a not-a-timer-event error", %{stub_name: stub_name, client: client} do
      Req.Test.stub(stub_name, fn conn ->
        conn |> Plug.Conn.put_status(422) |> Req.Test.json(%{"error" => "not_a_timer_event"})
      end)

      assert {:error, %Error{reason: :not_a_timer_event}} = Events.trigger_timer(client, "fni-1")
    end
  end
end
