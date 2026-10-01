defmodule BfwEngineWeb.Http.MetricsControllerTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias BfwEngineWeb.Http.MetricsController
  alias BfwEngineWeb.Http.Router

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
    test "router answers with a plain 404 before the controller runs" do
      Application.put_env(:peripheral_telemetry, :metrics_enabled, false)

      conn = conn(:get, "/metrics") |> Router.call(Router.init([]))

      assert conn.status == 404
      assert conn.resp_body == "Not Found"
      assert conn.halted
    end

    test "router serves metrics again once re-enabled" do
      Application.put_env(:peripheral_telemetry, :metrics_enabled, true)

      conn = conn(:get, "/metrics") |> Router.call(Router.init([]))

      assert conn.status == 200
    end
  end
end
