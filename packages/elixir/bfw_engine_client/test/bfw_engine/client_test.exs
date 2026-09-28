defmodule BfwEngine.ClientTest do
  use ExUnit.Case, async: true

  alias BfwEngine.Client
  alias BfwEngine.Client.Error

  describe "new/1" do
    test "raises when :base_url is missing" do
      assert_raise ArgumentError, ~r/requires the :base_url option/, fn ->
        Client.new(token: "eyJ...")
      end
    end

    test "builds a client with defaults" do
      client = Client.new(base_url: "http://localhost:4100")

      assert client.base_url == "http://localhost:4100"
      assert client.token == nil
      assert client.req_options == []
    end
  end

  describe "request/4" do
    setup do
      stub_name = {__MODULE__, :request_stub, System.unique_integer()}

      client =
        Client.new(base_url: "http://engine.invalid", req_options: [plug: {Req.Test, stub_name}])

      {:ok, stub_name: stub_name, client: client}
    end

    test "sends the given method, path, and body", %{stub_name: stub_name, client: client} do
      Req.Test.stub(stub_name, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/processes/order-process/start"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"payload" => %{"orderId" => 1}}
        Req.Test.json(conn, %{"processInstanceId" => "pi-1"})
      end)

      assert {:ok, %{"processInstanceId" => "pi-1"}} =
               Client.request(client, :post, "/processes/order-process/start",
                 json: %{"payload" => %{"orderId" => 1}}
               )
    end

    test "sends a bearer token from a static string", %{stub_name: stub_name} do
      client =
        Client.new(
          base_url: "http://engine.invalid",
          token: "static-token",
          req_options: [plug: {Req.Test, stub_name}]
        )

      Req.Test.stub(stub_name, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer static-token"]
        Req.Test.json(conn, %{})
      end)

      assert {:ok, %{}} = Client.request(client, :get, "/processes")
    end

    test "calls a token function per request", %{stub_name: stub_name} do
      counter = :counters.new(1, [])

      token_function = fn ->
        :counters.add(counter, 1, 1)
        "fresh-#{:counters.get(counter, 1)}"
      end

      client =
        Client.new(
          base_url: "http://engine.invalid",
          token: token_function,
          req_options: [plug: {Req.Test, stub_name}]
        )

      Req.Test.stub(stub_name, fn conn ->
        Req.Test.json(conn, %{"authorization" => Plug.Conn.get_req_header(conn, "authorization")})
      end)

      assert {:ok, %{"authorization" => ["Bearer fresh-1"]}} =
               Client.request(client, :get, "/processes")

      assert {:ok, %{"authorization" => ["Bearer fresh-2"]}} =
               Client.request(client, :get, "/processes")
    end

    test "sends no authorization header when the token is nil", %{
      stub_name: stub_name,
      client: client
    } do
      Req.Test.stub(stub_name, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == []
        Req.Test.json(conn, %{})
      end)

      assert {:ok, %{}} = Client.request(client, :get, "/processes")
    end

    test "maps a non-2xx JSON response to an Error", %{stub_name: stub_name, client: client} do
      Req.Test.stub(stub_name, fn conn ->
        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.json(%{"error" => "process_not_found", "message" => "no such process"})
      end)

      assert {:error, %Error{status: 404, reason: :process_not_found, message: "no such process"}} =
               Client.request(client, :get, "/processes/missing")
    end

    test "keeps map headers from req_options next to the bearer token", %{stub_name: stub_name} do
      client =
        Client.new(
          base_url: "http://engine.invalid",
          token: "static-token",
          req_options: [plug: {Req.Test, stub_name}, headers: %{"x-trace" => "trace-1"}]
        )

      Req.Test.stub(stub_name, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer static-token"]
        assert Plug.Conn.get_req_header(conn, "x-trace") == ["trace-1"]
        Req.Test.json(conn, %{})
      end)

      assert {:ok, %{}} = Client.request(client, :get, "/processes")
    end

    test "does not retry a 503 by default", %{stub_name: stub_name, client: client} do
      counter = :counters.new(1, [])

      Req.Test.stub(stub_name, fn conn ->
        :counters.add(counter, 1, 1)

        conn
        |> Plug.Conn.put_status(503)
        |> Req.Test.json(%{"error" => "engine_at_capacity"})
      end)

      assert {:error, %Error{reason: :engine_at_capacity}} =
               Client.request(client, :get, "/processes")

      assert :counters.get(counter, 1) == 1
    end

    test "returns the transport exception unchanged on a network failure", %{
      stub_name: stub_name,
      client: client
    } do
      Req.Test.stub(stub_name, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               Client.request(client, :get, "/processes")
    end
  end
end
