defmodule BfwEngine.Client.AdhocSubprocessesTest do
  use ExUnit.Case, async: true

  alias BfwEngine.Client
  alias BfwEngine.Client.AdhocSubprocesses
  alias BfwEngine.Client.Error

  setup do
    stub_name = {__MODULE__, System.unique_integer()}

    client =
      Client.new(base_url: "http://engine.invalid", req_options: [plug: {Req.Test, stub_name}])

    {:ok, stub_name: stub_name, client: client}
  end

  describe "activities/2" do
    test "GETs the activities endpoint and unwraps the data list", %{
      stub_name: stub_name,
      client: client
    } do
      Req.Test.stub(stub_name, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/adhoc-subprocesses/pi-1/activities"

        Req.Test.json(conn, %{
          "data" => [%{"id" => "Task_1", "enabled" => true, "performedCount" => 0}]
        })
      end)

      assert {:ok, [%{"id" => "Task_1", "enabled" => true}]} =
               AdhocSubprocesses.activities(client, "pi-1")
    end

    test "maps a not-adhoc-subprocess error", %{stub_name: stub_name, client: client} do
      Req.Test.stub(stub_name, fn conn ->
        conn |> Plug.Conn.put_status(422) |> Req.Test.json(%{"error" => "not_adhoc_subprocess"})
      end)

      assert {:error, %Error{reason: :validation_error}} =
               AdhocSubprocesses.activities(client, "pi-1")
    end
  end

  describe "activate/3" do
    test "POSTs to the activate endpoint", %{stub_name: stub_name, client: client} do
      Req.Test.stub(stub_name, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/adhoc-subprocesses/pi-1/activities/Task_1/activate"
        Req.Test.json(conn, %{"flowNodeInstanceId" => "fni-1"})
      end)

      assert {:ok, %{"flowNodeInstanceId" => "fni-1"}} =
               AdhocSubprocesses.activate(client, "pi-1", "Task_1")
    end
  end

  describe "complete/2" do
    test "POSTs to the complete endpoint", %{stub_name: stub_name, client: client} do
      Req.Test.stub(stub_name, fn conn ->
        assert conn.request_path == "/adhoc-subprocesses/pi-1/complete"
        Req.Test.json(conn, %{"completed" => true})
      end)

      assert {:ok, %{"completed" => true}} = AdhocSubprocesses.complete(client, "pi-1")
    end
  end

  describe "status/2" do
    test "GETs the status endpoint", %{stub_name: stub_name, client: client} do
      Req.Test.stub(stub_name, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/adhoc-subprocesses/pi-1/status"
        Req.Test.json(conn, %{"activeCount" => 0, "completionSignaled" => false})
      end)

      assert {:ok, %{"activeCount" => 0, "completionSignaled" => false}} =
               AdhocSubprocesses.status(client, "pi-1")
    end

    test "maps a not-found error", %{stub_name: stub_name, client: client} do
      Req.Test.stub(stub_name, fn conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"error" => "not_found"})
      end)

      assert {:error, %Error{reason: :not_found}} = AdhocSubprocesses.status(client, "pi-1")
    end
  end
end
