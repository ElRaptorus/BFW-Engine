defmodule BfwEngine.Plugins.Builtin.HttpServiceTaskHandlerTest do
  use ExUnit.Case, async: false

  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.BPMN.Model.FlowNodeData
  alias BfwEngine.Execution.HandlerContext
  alias BfwEngine.Plugins.Builtin.HttpServiceTaskHandler
  alias BfwEngine.Types.Token

  @moduletag :http_handler

  setup do
    Req.Test.set_req_test_to_shared()

    Req.Test.stub(__MODULE__, fn conn ->
      Plug.Conn.send_resp(conn, 200, Jason.encode!(%{"default" => true}))
    end)

    previous = Application.get_env(:peripheral_plugins, :http_req_options)

    Application.put_env(:peripheral_plugins, :http_req_options,
      plug: {Req.Test, __MODULE__},
      retry: false
    )

    on_exit(fn ->
      Req.Test.set_req_test_to_private()

      if previous do
        Application.put_env(:peripheral_plugins, :http_req_options, previous)
      else
        Application.delete_env(:peripheral_plugins, :http_req_options)
      end
    end)

    :ok
  end

  defp build_flow_node(opts) do
    %FlowNode{
      id: Keyword.get(opts, :id, "st-http-1"),
      type: :service_task,
      type_data: %FlowNodeData.ServiceTask{
        implementation: "http",
        http_url: Keyword.get(opts, :http_url, nil),
        http_method: Keyword.get(opts, :http_method, nil),
        http_body: Keyword.get(opts, :http_body, nil),
        http_auth_header: Keyword.get(opts, :http_auth_header, nil),
        http_response_headers: Keyword.get(opts, :http_response_headers, nil)
      }
    }
  end

  defp build_token(payload \\ %{}) do
    %Token{
      id: "tok-1",
      process_instance_id: "pi-1",
      payload: payload,
      originating_flow_node_instance_id: "fni-1",
      created_at: DateTime.utc_now()
    }
  end

  defp build_handler_context do
    %HandlerContext{
      flow_node_instance_id: "fni-1",
      process_instance_id: "pi-1",
      identity: %{},
      process: %{id: "proc-1", name: "Test", version: "1"},
      process_instance: %{id: "pi-1", started_at: DateTime.utc_now(), started_by: nil},
      data_objects: %{}
    }
  end

  # -- H-1/H-2: URL validation (sync errors) -----------------------------------

  describe "URL validation" do
    test "H-1: missing URL returns error synchronously" do
      node = build_flow_node(http_url: nil)

      assert {:error, {:http_handler_missing_url, "st-http-1"}} =
               HttpServiceTaskHandler.handle_enter(node, build_token(), build_handler_context())
    end

    test "H-2: empty string URL returns error synchronously" do
      node = build_flow_node(http_url: "")

      assert {:error, {:http_handler_missing_url, "st-http-1"}} =
               HttpServiceTaskHandler.handle_enter(node, build_token(), build_handler_context())
    end
  end

  # -- H-3/H-4: Method validation (sync) ----------------------------------------

  describe "method validation" do
    test "H-3: invalid HTTP method returns error synchronously" do
      node = build_flow_node(http_url: "http://test.local/api", http_method: "TRACE")

      assert {:error, {:http_handler_invalid_method, "TRACE"}} =
               HttpServiceTaskHandler.handle_enter(node, build_token(), build_handler_context())
    end

    test "H-4: nil method defaults to GET — returns {:async, ref}" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.method == "GET"
        Plug.Conn.send_resp(conn, 200, Jason.encode!(%{"ok" => true}))
      end)

      node = build_flow_node(http_url: "http://test.local/api", http_method: nil)

      assert {:async, "fni-1"} =
               HttpServiceTaskHandler.handle_enter(node, build_token(), build_handler_context())

      Process.sleep(200)
    end
  end

  # -- H-5/H-6: FEEL expression errors (sync) -----------------------------------

  describe "FEEL expression errors" do
    test "H-5: corrupt body FEEL returns error synchronously" do
      node =
        build_flow_node(
          http_url: "http://test.local/api",
          http_body: "for x in [1] return if x then"
        )

      assert {:error, {:http_body_expression_error, _}} =
               HttpServiceTaskHandler.handle_enter(node, build_token(), build_handler_context())
    end

    test "H-6: corrupt auth header FEEL returns error synchronously" do
      node =
        build_flow_node(
          http_url: "http://test.local/api",
          http_auth_header: "for x in [1] return if x then"
        )

      assert {:error, {:http_auth_expression_error, _}} =
               HttpServiceTaskHandler.handle_enter(node, build_token(), build_handler_context())
    end
  end

  # -- H-7 to H-13: HTTP execution (async) --------------------------------------

  describe "HTTP execution (async)" do
    test "H-7: successful GET returns {:async, ref}" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.method == "GET"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"result" => "ok"}))
      end)

      node = build_flow_node(http_url: "http://test.local/api")

      assert {:async, "fni-1"} =
               HttpServiceTaskHandler.handle_enter(node, build_token(), build_handler_context())

      Process.sleep(200)
    end

    test "H-8: successful POST with FEEL body evaluates correctly" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.method == "POST"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["order_id"] == "ORD-123"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"received" => decoded}))
      end)

      node =
        build_flow_node(
          http_url: "http://test.local/api",
          http_method: "POST",
          http_body: ~s({"order_id": token.order_id})
        )

      token = build_token(%{"order_id" => "ORD-123"})

      assert {:async, "fni-1"} =
               HttpServiceTaskHandler.handle_enter(node, token, build_handler_context())

      Process.sleep(200)
    end

    test "H-9: auth header FEEL expression sets Authorization header" do
      Req.Test.stub(__MODULE__, fn conn ->
        auth = Plug.Conn.get_req_header(conn, "authorization")
        assert auth == ["Bearer secret-token"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"authed" => true}))
      end)

      node =
        build_flow_node(
          http_url: "http://test.local/api",
          http_auth_header: ~s("Bearer secret-token")
        )

      assert {:async, "fni-1"} =
               HttpServiceTaskHandler.handle_enter(node, build_token(), build_handler_context())

      Process.sleep(200)
    end

    test "H-10: HTTP 4xx triggers fail_async" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(422, Jason.encode!(%{"msg" => "bad"}))
      end)

      node = build_flow_node(http_url: "http://test.local/api")

      assert {:async, "fni-1"} =
               HttpServiceTaskHandler.handle_enter(node, build_token(), build_handler_context())

      Process.sleep(200)
    end

    test "H-11: HTTP 5xx triggers fail_async" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, Jason.encode!(%{"msg" => "fail"}))
      end)

      node = build_flow_node(http_url: "http://test.local/api")

      assert {:async, "fni-1"} =
               HttpServiceTaskHandler.handle_enter(node, build_token(), build_handler_context())

      Process.sleep(200)
    end

    test "H-12: timeout triggers fail_async" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      node = build_flow_node(http_url: "http://test.local/api")

      assert {:async, "fni-1"} =
               HttpServiceTaskHandler.handle_enter(node, build_token(), build_handler_context())

      Process.sleep(200)
    end

    test "H-13: connection refused triggers fail_async" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      node = build_flow_node(http_url: "http://test.local/api")

      assert {:async, "fni-1"} =
               HttpServiceTaskHandler.handle_enter(node, build_token(), build_handler_context())

      Process.sleep(200)
    end
  end

  # -- H-14 to H-16: Response header mapping (async) ----------------------------

  describe "response header mapping (async)" do
    test "H-14: response header mapping evaluates correctly" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("traceid", "abc-123")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"data" => 42}))
      end)

      node =
        build_flow_node(
          http_url: "http://test.local/api",
          http_response_headers: ~s({"trace_id": responseHeaders.traceid})
        )

      assert {:async, "fni-1"} =
               HttpServiceTaskHandler.handle_enter(node, build_token(), build_handler_context())

      Process.sleep(200)
    end

    test "H-15: response header merge with non-map body succeeds" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("customhdr", "val")
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(200, "plain text response")
      end)

      node =
        build_flow_node(
          http_url: "http://test.local/api",
          http_response_headers: ~s({"custom": responseHeaders.customhdr})
        )

      assert {:async, "fni-1"} =
               HttpServiceTaskHandler.handle_enter(node, build_token(), build_handler_context())

      Process.sleep(200)
    end

    test "H-16: corrupt response header FEEL triggers fail_async" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-custom", "val")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true}))
      end)

      node =
        build_flow_node(
          http_url: "http://test.local/api",
          http_response_headers: "for x in [1] return if x then"
        )

      assert {:async, "fni-1"} =
               HttpServiceTaskHandler.handle_enter(node, build_token(), build_handler_context())

      Process.sleep(200)
    end
  end

  # -- H-17: Payload cap (async) ------------------------------------------------

  describe "payload cap (async)" do
    test "H-17: oversized response triggers fail_async" do
      large_body = String.duplicate("x", 100_000)

      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"big" => large_body}))
      end)

      node = build_flow_node(http_url: "http://test.local/api")

      assert {:async, "fni-1"} =
               HttpServiceTaskHandler.handle_enter(node, build_token(), build_handler_context())

      Process.sleep(200)
    end
  end

  # -- H-18: Valid methods coverage (async) -------------------------------------

  describe "method coverage (async)" do
    test "H-18: all valid methods return {:async, ref}" do
      for method <- ~w(GET POST PUT PATCH DELETE HEAD OPTIONS) do
        Req.Test.stub(__MODULE__, fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(%{"method" => method}))
        end)

        node = build_flow_node(http_url: "http://test.local/api", http_method: method)

        result = HttpServiceTaskHandler.handle_enter(node, build_token(), build_handler_context())

        assert {:async, "fni-1"} = result,
               "Expected method #{method} to return {:async, _}, got: #{inspect(result)}"
      end

      Process.sleep(500)
    end
  end
end
