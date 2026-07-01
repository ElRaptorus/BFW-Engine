defmodule Examples.ServiceTaskHandlers.HttpEnrichment.HttpEnrichmentHandler do
  @moduledoc """
  Calls a JSON HTTP endpoint, then merges the decoded body into the Service Task
  output alongside caller metadata from `handler_context.identity`.

  ## Async contract

  `handle_enter/3` validates inputs synchronously, then spawns a Task for
  the actual HTTP call and returns `{:async, flow_node_instance_id}`. The
  spawned Task calls `finish_async` on success or `fail_async` on failure.

  ## Built-in `"http"` handler versus this example

  The engine ships `EvilEngine.Plugins.Builtin.HttpServiceTaskHandler`, registered
  for `implementation="http"`. It reads `evil:httpUrl`, `evil:httpMethod`, and FEEL
  expressions for body and headers from **BPMN extension elements**, evaluates them
  against the handler context, and performs the request without a separate Elixir module.

  This handler is for teams that need **full control in code**: custom TLS policies,
  non-JSON bodies, retries, proprietary signing, audit hooks, or orchestration that
  is awkward to express as static BPMN extensions.
  """

  @behaviour EvilEngine.Plugin.ServiceTaskHandler

  @doc "Validates inputs synchronously, then spawns async HTTP call."
  @impl true
  def handle_enter(flow_node, token, handler_context) do
    flow_node_instance_id = handler_context.flow_node_instance_id
    url = Map.get(token.payload, "enrichment_url")

    unless is_binary(url) do
      {:error, :missing_enrichment_url}
    else
      type_data = flow_node.type_data
      identity = handler_context.identity
      facade = Examples.ServiceTaskHandlers.HttpEnrichment.HttpEnrichmentFacadeStore.get()

      Task.start(fn ->
        case fetch_json_body(url) do
          {:ok, body_map} ->
            output =
              body_map
              |> Map.put("enrichment_source", url)
              |> Map.put("handler_implementation", type_data.implementation)
              |> Map.put("requested_by", Map.get(identity, "sub"))

            facade.service_tasks.finish_async.(flow_node_instance_id, output)

          {:error, reason} ->
            facade.service_tasks.fail_async.(
              flow_node_instance_id,
              "HTTP_ENRICHMENT_ERROR",
              inspect(reason)
            )
        end
      end)

      {:async, flow_node_instance_id}
    end
  end

  defp fetch_json_body(url) do
    case request_http_get(url) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, map} when is_map(map) ->
            {:ok, stringify_keys(map)}

          {:ok, _} ->
            {:error, :json_not_object}

          {:error, _} ->
            {:error, :invalid_json}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request_http_get(url) do
    case Process.get(:examples_http_enrichment_request_stub) do
      function when is_function(function, 1) ->
        function.(url)

      _ ->
        http_get(url)
    end
  end

  defp http_get(url) do
    case :httpc.request(:get, {String.to_charlist(url), []}, [], body_format: :binary) do
      {:ok, {{_http_version, status_code, _reason_phrase}, _headers, body}}
      when status_code >= 200 and status_code < 300 and is_binary(body) ->
        {:ok, body}

      {:ok, {{_http_version, status_code, _reason_phrase}, _headers, _body}} ->
        {:error, {:http_error_status, status_code}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
