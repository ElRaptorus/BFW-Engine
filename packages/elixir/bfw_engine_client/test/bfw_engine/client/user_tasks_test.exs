defmodule BfwEngine.Client.UserTasksTest do
  use ExUnit.Case, async: true

  alias BfwEngine.Client
  alias BfwEngine.Client.Error
  alias BfwEngine.Client.UserTasks

  setup do
    stub_name = {__MODULE__, System.unique_integer()}

    client =
      Client.new(base_url: "http://engine.invalid", req_options: [plug: {Req.Test, stub_name}])

    {:ok, stub_name: stub_name, client: client}
  end

  describe "list_waiting/1" do
    test "queries waiting user and manual tasks with typeProperties passed through", %{
      stub_name: stub_name,
      client: client
    } do
      Req.Test.stub(stub_name, fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw_body)

        assert body["variables"] == %{
                 "state" => "waiting",
                 "flowNodeTypeIn" => ["user_task", "manual_task"],
                 "limit" => 10,
                 "offset" => 20
               }

        Req.Test.json(conn, %{
          "data" => %{
            "flowNodeInstances" => %{
              "results" => [
                %{
                  "id" => "fni-1",
                  "flowNodeType" => "user_task",
                  "typeProperties" => %{
                    "form_schema" => [
                      %{
                        "id" => "approved",
                        "type" => "toggle",
                        "label" => "approved",
                        "required" => false
                      }
                    ]
                  }
                }
              ]
            }
          }
        })
      end)

      assert {:ok, [result]} = UserTasks.list_waiting(client, limit: 10, offset: 20)
      assert result["flowNodeType"] == "user_task"

      assert result["typeProperties"]["form_schema"] == [
               %{
                 "id" => "approved",
                 "type" => "toggle",
                 "label" => "approved",
                 "required" => false
               }
             ]
    end

    test "maps an unauthorized error", %{stub_name: stub_name, client: client} do
      Req.Test.stub(stub_name, fn conn ->
        conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => "unauthorized"})
      end)

      assert {:error, %Error{reason: :unauthorized}} = UserTasks.list_waiting(client)
    end
  end

  describe "finish/3" do
    test "PUTs the finish endpoint with values and an action id", %{
      stub_name: stub_name,
      client: client
    } do
      Req.Test.stub(stub_name, fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "/user-tasks/fni-1/finish"
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)

        assert Jason.decode!(raw_body) == %{
                 "values" => %{"approved" => true},
                 "actionId" => "confirm"
               }

        Plug.Conn.send_resp(conn, 204, "")
      end)

      assert {:ok, ""} =
               UserTasks.finish(client, "fni-1",
                 values: %{"approved" => true},
                 action_id: "confirm"
               )
    end

    test "omits values and actionId when absent", %{stub_name: stub_name, client: client} do
      Req.Test.stub(stub_name, fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw_body) == %{}
        Plug.Conn.send_resp(conn, 204, "")
      end)

      assert {:ok, ""} = UserTasks.finish(client, "fni-1")
    end
  end

  describe "cancel/3" do
    test "PUTs the cancel endpoint with an optional reason", %{
      stub_name: stub_name,
      client: client
    } do
      Req.Test.stub(stub_name, fn conn ->
        assert conn.request_path == "/user-tasks/fni-1/cancel"
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw_body) == %{"reason" => "no longer needed"}
        Plug.Conn.send_resp(conn, 204, "")
      end)

      assert {:ok, ""} = UserTasks.cancel(client, "fni-1", reason: "no longer needed")
    end

    test "maps a fni-not-waiting conflict", %{stub_name: stub_name, client: client} do
      Req.Test.stub(stub_name, fn conn ->
        conn |> Plug.Conn.put_status(409) |> Req.Test.json(%{"error" => "fni_not_waiting"})
      end)

      assert {:error, %Error{reason: :fni_not_waiting}} = UserTasks.cancel(client, "fni-1")
    end
  end
end
