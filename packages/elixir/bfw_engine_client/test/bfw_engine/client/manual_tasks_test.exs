defmodule BfwEngine.Client.ManualTasksTest do
  use ExUnit.Case, async: true

  alias BfwEngine.Client
  alias BfwEngine.Client.Error
  alias BfwEngine.Client.ManualTasks

  setup do
    stub_name = {__MODULE__, System.unique_integer()}

    client =
      Client.new(base_url: "http://engine.invalid", req_options: [plug: {Req.Test, stub_name}])

    {:ok, stub_name: stub_name, client: client}
  end

  describe "confirm/2" do
    test "PUTs the confirm endpoint without a body", %{stub_name: stub_name, client: client} do
      Req.Test.stub(stub_name, fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "/manual-tasks/fni-1/confirm"
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        assert raw_body == ""
        Plug.Conn.send_resp(conn, 204, "")
      end)

      assert {:ok, ""} = ManualTasks.confirm(client, "fni-1")
    end

    test "maps a not-found error", %{stub_name: stub_name, client: client} do
      Req.Test.stub(stub_name, fn conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"error" => "not_found"})
      end)

      assert {:error, %Error{reason: :not_found}} = ManualTasks.confirm(client, "fni-1")
    end
  end

  describe "cancel/3" do
    test "PUTs the cancel endpoint with an optional reason", %{
      stub_name: stub_name,
      client: client
    } do
      Req.Test.stub(stub_name, fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "/manual-tasks/fni-1/cancel"
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw_body) == %{"reason" => "no longer needed"}
        Plug.Conn.send_resp(conn, 204, "")
      end)

      assert {:ok, ""} = ManualTasks.cancel(client, "fni-1", reason: "no longer needed")
    end

    test "omits the reason when absent", %{stub_name: stub_name, client: client} do
      Req.Test.stub(stub_name, fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw_body) == %{}
        Plug.Conn.send_resp(conn, 204, "")
      end)

      assert {:ok, ""} = ManualTasks.cancel(client, "fni-1")
    end
  end
end
