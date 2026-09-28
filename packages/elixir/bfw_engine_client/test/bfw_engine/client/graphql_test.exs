defmodule BfwEngine.Client.GraphqlTest do
  use ExUnit.Case, async: true

  alias BfwEngine.Client
  alias BfwEngine.Client.Error
  alias BfwEngine.Client.Graphql

  setup do
    stub_name = {__MODULE__, System.unique_integer()}

    client =
      Client.new(base_url: "http://engine.invalid", req_options: [plug: {Req.Test, stub_name}])

    {:ok, stub_name: stub_name, client: client}
  end

  test "POSTs the document and variables and returns the data object", %{
    stub_name: stub_name,
    client: client
  } do
    Req.Test.stub(stub_name, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/v1/graphql"
      {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw_body)
      assert body["query"] == "query { ping }"
      assert body["variables"] == %{"id" => "pi-1"}
      Req.Test.json(conn, %{"data" => %{"ping" => "pong"}})
    end)

    assert {:ok, %{"ping" => "pong"}} = Graphql.query(client, "query { ping }", %{"id" => "pi-1"})
  end

  test "defaults variables to an empty map", %{stub_name: stub_name, client: client} do
    Req.Test.stub(stub_name, fn conn ->
      {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(raw_body)["variables"] == %{}
      Req.Test.json(conn, %{"data" => %{}})
    end)

    assert {:ok, %{}} = Graphql.query(client, "query { ping }")
  end

  test "maps the first errors[] entry through extensions.code", %{
    stub_name: stub_name,
    client: client
  } do
    Req.Test.stub(stub_name, fn conn ->
      Req.Test.json(conn, %{
        "errors" => [
          %{"message" => "not found", "extensions" => %{"code" => "process_not_found"}},
          %{"message" => "second error"}
        ]
      })
    end)

    assert {:error, %Error{reason: :process_not_found, message: "not found"}} =
             Graphql.query(client, "query { ping }")
  end

  test "propagates a transport-level failure", %{stub_name: stub_name} do
    client =
      Client.new(
        base_url: "http://engine.invalid",
        req_options: [plug: {Req.Test, stub_name}, retry: false]
      )

    Req.Test.stub(stub_name, fn conn -> Req.Test.transport_error(conn, :timeout) end)

    assert {:error, %Req.TransportError{reason: :timeout}} =
             Graphql.query(client, "query { ping }")
  end
end
