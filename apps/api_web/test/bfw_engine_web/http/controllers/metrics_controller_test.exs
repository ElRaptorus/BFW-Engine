defmodule BfwEngineWeb.Http.MetricsControllerTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias BfwEngineWeb.Http.MetricsController

  setup do
    original = Application.get_env(:peripheral_telemetry, :metrics_enabled)

    on_exit(fn ->
      if original != nil do
        Application.put_env(:peripheral_telemetry, :metrics_enabled, original)
      else
        Application.delete_env(:peripheral_telemetry, :metrics_enabled)
      end
    end)

    :ok
  end

  describe "index/2 when metrics enabled" do
    test "returns 200 with text/plain content type" do
      Application.put_env(:peripheral_telemetry, :metrics_enabled, true)

      conn =
        conn(:get, "/metrics")
        |> put_private(:phoenix_format, "json")
        |> MetricsController.index(%{})

      assert conn.status == 200

      content_type =
        Enum.find_value(conn.resp_headers, fn
          {"content-type", value} -> value
          _ -> nil
        end)

      assert content_type =~ "text/plain"
    end

    test "returns non-empty body from Prometheus scrape" do
      Application.put_env(:peripheral_telemetry, :metrics_enabled, true)

      conn =
        conn(:get, "/metrics")
        |> put_private(:phoenix_format, "json")
        |> MetricsController.index(%{})

      assert conn.status == 200
      assert is_binary(conn.resp_body)
    end
  end

  describe "index/2 when metrics disabled" do
    test "returns 404 with metrics_disabled error" do
      Application.put_env(:peripheral_telemetry, :metrics_enabled, false)

      conn =
        conn(:get, "/metrics")
        |> put_private(:phoenix_format, "json")
        |> put_private(:phoenix_endpoint, BfwEngineWeb.Http.Endpoint)
        |> put_private(:phoenix_router, BfwEngineWeb.Http.Router)
        |> MetricsController.index(%{})

      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "metrics_disabled"
    end
  end
end
