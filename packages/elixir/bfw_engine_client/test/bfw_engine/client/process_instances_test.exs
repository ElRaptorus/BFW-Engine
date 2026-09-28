defmodule BfwEngine.Client.ProcessInstancesTest do
  use ExUnit.Case, async: true

  alias BfwEngine.Client
  alias BfwEngine.Client.Error
  alias BfwEngine.Client.ProcessInstances

  setup do
    stub_name = {__MODULE__, System.unique_integer()}

    client =
      Client.new(base_url: "http://engine.invalid", req_options: [plug: {Req.Test, stub_name}])

    {:ok, stub_name: stub_name, client: client}
  end

  describe "get/2" do
    test "queries state, version, and timestamps via GraphQL", %{
      stub_name: stub_name,
      client: client
    } do
      Req.Test.stub(stub_name, fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw_body)
        assert body["variables"] == %{"id" => "pi-1"}
        assert body["query"] =~ "getProcessInstance"
        assert body["query"] =~ "processVersion"

        Req.Test.json(conn, %{
          "data" => %{
            "getProcessInstance" => %{
              "id" => "pi-1",
              "state" => "finished",
              "processVersion" => %{"version" => "1.0.0"},
              "startedAt" => "2026-01-01T00:00:00Z",
              "finishedAt" => "2026-01-01T00:01:00Z"
            }
          }
        })
      end)

      assert {:ok, %{"state" => "finished", "processVersion" => %{"version" => "1.0.0"}}} =
               ProcessInstances.get(client, "pi-1")
    end

    test "maps a not-found error", %{stub_name: stub_name, client: client} do
      Req.Test.stub(stub_name, fn conn ->
        Req.Test.json(conn, %{
          "errors" => [%{"message" => "gone", "extensions" => %{"code" => "not_found"}}]
        })
      end)

      assert {:error, %Error{reason: :not_found}} = ProcessInstances.get(client, "missing")
    end

    test "maps a null getProcessInstance to not_found without echoing the token", %{
      stub_name: stub_name
    } do
      token = "do-not-leak-this-token"

      client =
        Client.new(
          base_url: "http://engine.invalid",
          token: token,
          req_options: [plug: {Req.Test, stub_name}]
        )

      Req.Test.stub(stub_name, fn conn ->
        Req.Test.json(conn, %{"data" => %{"getProcessInstance" => nil}})
      end)

      assert {:error,
              %Error{status: 404, code: "not_found", reason: :not_found, message: "not found"} =
                error} = ProcessInstances.get(client, "missing")

      refute inspect(error) =~ token
    end
  end

  describe "abort/3" do
    test "PUTs the abort endpoint with an optional reason", %{
      stub_name: stub_name,
      client: client
    } do
      Req.Test.stub(stub_name, fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "/process-instances/pi-1/abort"
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw_body) == %{"reason" => "operator abort"}
        Plug.Conn.send_resp(conn, 204, "")
      end)

      assert {:ok, ""} = ProcessInstances.abort(client, "pi-1", reason: "operator abort")
    end

    test "omits the reason when absent", %{stub_name: stub_name, client: client} do
      Req.Test.stub(stub_name, fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw_body) == %{}
        Plug.Conn.send_resp(conn, 204, "")
      end)

      assert {:ok, ""} = ProcessInstances.abort(client, "pi-1")
    end

    test "maps a forbidden error", %{stub_name: stub_name, client: client} do
      Req.Test.stub(stub_name, fn conn ->
        conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"error" => "forbidden"})
      end)

      assert {:error, %Error{reason: :forbidden}} = ProcessInstances.abort(client, "pi-1")
    end
  end

  describe "waiting_catches/2" do
    test "queries waiting catch-side flow node instances with typeProperties passed through", %{
      stub_name: stub_name,
      client: client
    } do
      Req.Test.stub(stub_name, fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw_body)

        assert body["variables"] == %{
                 "processInstanceId" => "pi-1",
                 "state" => "waiting",
                 "flowNodeTypeIn" => [
                   "intermediate_catch_event",
                   "boundary_event",
                   "receive_task"
                 ],
                 "limit" => 5,
                 "offset" => 15
               }

        Req.Test.json(conn, %{
          "data" => %{
            "flowNodeInstances" => %{
              "results" => [
                %{
                  "id" => "fni-1",
                  "flowNodeType" => "intermediate_catch_event",
                  "eventType" => "message",
                  "typeProperties" => %{
                    "message_name" => "order-paid",
                    "expected_correlation_value" => "order-1"
                  }
                }
              ]
            }
          }
        })
      end)

      assert {:ok, [result]} =
               ProcessInstances.waiting_catches(client, "pi-1", limit: 5, offset: 15)

      assert result["typeProperties"]["message_name"] == "order-paid"
      assert result["typeProperties"]["expected_correlation_value"] == "order-1"
    end
  end
end
