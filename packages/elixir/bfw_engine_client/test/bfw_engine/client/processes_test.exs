defmodule BfwEngine.Client.ProcessesTest do
  use ExUnit.Case, async: true

  alias BfwEngine.Client
  alias BfwEngine.Client.Error
  alias BfwEngine.Client.Processes

  setup do
    stub_name = {__MODULE__, System.unique_integer()}

    client =
      Client.new(base_url: "http://engine.invalid", req_options: [plug: {Req.Test, stub_name}])

    {:ok, stub_name: stub_name, client: client}
  end

  describe "list/1" do
    test "GETs /processes and returns the decoded list", %{stub_name: stub_name, client: client} do
      Req.Test.stub(stub_name, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/processes"
        Req.Test.json(conn, [%{"id" => "order-process", "enabled" => true}])
      end)

      assert {:ok, [%{"id" => "order-process", "enabled" => true}]} = Processes.list(client)
    end

    test "maps a non-2xx response to an Error", %{stub_name: stub_name, client: client} do
      Req.Test.stub(stub_name, fn conn ->
        conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => "unauthorized"})
      end)

      assert {:error, %Error{reason: :unauthorized}} = Processes.list(client)
    end
  end

  describe "start/3" do
    test "POSTs with camelCase keys and no version field", %{stub_name: stub_name, client: client} do
      Req.Test.stub(stub_name, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/processes/order-process/start"
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw_body)

        assert body == %{
                 "startEventId" => "Start_1",
                 "payload" => %{"orderId" => 1},
                 "context" => %{"tenant" => "acme"},
                 "businessKey" => "order-1"
               }

        refute Map.has_key?(body, "version")
        Req.Test.json(conn, %{"processInstanceId" => "pi-1"})
      end)

      assert {:ok, %{"processInstanceId" => "pi-1"}} =
               Processes.start(client, "order-process",
                 start_event_id: "Start_1",
                 payload: %{"orderId" => 1},
                 context: %{"tenant" => "acme"},
                 business_key: "order-1"
               )
    end

    test "omits absent options entirely", %{stub_name: stub_name, client: client} do
      Req.Test.stub(stub_name, fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw_body) == %{}
        Req.Test.json(conn, %{"processInstanceId" => "pi-1"})
      end)

      assert {:ok, _} = Processes.start(client, "order-process")
    end

    test "maps a validation error", %{stub_name: stub_name, client: client} do
      Req.Test.stub(stub_name, fn conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"error" => "start_event_not_found"})
      end)

      assert {:error, %Error{reason: :start_event_not_found}} =
               Processes.start(client, "order-process", start_event_id: "Nope")
    end
  end
end
