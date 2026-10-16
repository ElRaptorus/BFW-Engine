defmodule BfwEngine.Plugins.Builtin.HttpServiceTaskHandler do
  @moduledoc """
  Built-in HTTP Service Task handler.

  Performs asynchronous HTTP requests based on `bfw:http*` extension
  elements on Service Tasks with **implementation** `"http"`. Lives in
  `engine_plugins` to keep the HTTP client out of Core and to
  serve as a reference plugin implementation.

  ## Async lifecycle

  `handle_enter/3` validates inputs and evaluates FEEL expressions
  synchronously, then spawns a Task for the actual HTTP call and
  returns `{:async, flow_node_instance_id}`. The spawned Task calls
  `BfwEngine.Execution.finish_async_service_task/2` on success or
  `BfwEngine.Execution.fail_async_service_task/3` on failure.

  Validation errors (missing URL, invalid method, FEEL evaluation
  failure, an authorization header that is not a string or number) are
  returned as `{:error, reason}` synchronously — these are caught by
  `BoundaryAwareHandler.wrap_enter/4` and can trigger error boundary
  events. A raise inside the spawned Task (for example a malformed URL)
  fails the task with error code `HTTP_REQUEST_FAILED`.

  ## Engine restart

  An in-flight request does not survive an engine restart.
  `handle_resume/2` fails each resumed waiting task with error code
  `HTTP_INTERRUPTED`; the request is not re-issued, so an error boundary
  decides how to continue.

  ## Extension elements

  | Element | FEEL? | Description |
  |---------|-------|-------------|
  | `bfw:httpUrl` | No | Target URL (required) |
  | `bfw:httpMethod` | No | HTTP verb, default `GET` |
  | `bfw:httpBody` | Yes | Request body expression |
  | `bfw:httpAuthHeader` | Yes | Authorization header expression |
  | `bfw:httpResponseHeaders` | Yes | Response header mapping expression |
  """

  @behaviour BfwEngine.Plugin.ServiceTaskHandler

  require Logger

  alias BfwEngine.Execution
  alias BfwEngine.Execution.PayloadCap
  alias BfwEngine.Expressions.Context, as: FeelContext

  @valid_methods ~w(GET POST PUT PATCH DELETE HEAD OPTIONS)
  @default_method "GET"
  @request_timeout_ms 30_000
  @error_body_max_characters 500

  @impl true
  def handle_enter(flow_node, token, handler_context) do
    type_data = flow_node.type_data
    flow_node_instance_id = handler_context.flow_node_instance_id

    with {:ok, url} <- validate_url(type_data, flow_node.id),
         {:ok, method} <- validate_method(type_data),
         {:ok, body} <- evaluate_body(type_data, flow_node, token, handler_context),
         {:ok, auth_header} <- evaluate_auth_header(type_data, flow_node, token, handler_context) do
      req_opts = build_req_opts(url, method, body, auth_header)

      {:ok, _pid} =
        Task.start(fn ->
          execute_and_complete(
            req_opts,
            url,
            type_data,
            flow_node,
            token,
            handler_context,
            flow_node_instance_id
          )
        end)

      {:async, flow_node_instance_id}
    end
  end

  @impl true
  def handle_resume(%{flow_node: flow_node}, handler_context) do
    message =
      "HTTP service task '#{flow_node.id}'#{task_name_suffix(flow_node)} was interrupted by an engine " <>
        "restart while its request to #{flow_node.type_data.http_url} was in flight; " <>
        "the request is not re-issued"

    report_completion(
      handler_context.flow_node_instance_id,
      Execution.fail_async_service_task(
        handler_context.flow_node_instance_id,
        "HTTP_INTERRUPTED",
        message
      )
    )
  end

  defp task_name_suffix(%{name: name}) when is_binary(name) and name != "", do: " ('#{name}')"
  defp task_name_suffix(_flow_node), do: ""

  defp execute_and_complete(
         req_opts,
         url,
         type_data,
         flow_node,
         token,
         handler_context,
         flow_node_instance_id
       ) do
    completion =
      case execute_request(req_opts, url, type_data, flow_node, token, handler_context) do
        {:ok, output} ->
          Execution.finish_async_service_task(flow_node_instance_id, output)

        {:error, reason} ->
          Execution.fail_async_service_task(
            flow_node_instance_id,
            error_code(reason),
            error_message(reason)
          )
      end

    report_completion(flow_node_instance_id, completion)
  end

  defp report_completion(_flow_node_instance_id, :ok), do: :ok

  defp report_completion(flow_node_instance_id, error) do
    Logger.warning(
      "HTTP service task handler could not complete flow node instance #{flow_node_instance_id}: " <>
        inspect(error)
    )

    error
  end

  defp error_code({:http_timeout, _url}), do: "HTTP_TIMEOUT"
  defp error_code({:http_connection_failed, _url, _failure}), do: "HTTP_CONNECTION_FAILED"
  defp error_code({:http_error, status, _body}), do: "HTTP_#{status}"
  defp error_code(:payload_too_large), do: "PAYLOAD_TOO_LARGE"
  defp error_code({:http_request_failed, _url, _message}), do: "HTTP_REQUEST_FAILED"
  defp error_code(_reason), do: "HTTP_ERROR"

  defp error_message({:http_timeout, url}),
    do: "HTTP request to #{url} timed out after #{@request_timeout_ms} ms"

  defp error_message({:http_connection_failed, url, failure}),
    do: "HTTP request to #{url} failed: #{failure}"

  defp error_message({:http_error, status, body}) do
    "HTTP request answered status #{status}; response body (first #{@error_body_max_characters} " <>
      "characters): #{truncate_body(body)}"
  end

  defp error_message(:payload_too_large),
    do: "The HTTP response is larger than the engine's payload cap"

  defp error_message({:http_request_failed, url, message}),
    do: "HTTP request to #{url} could not be executed: #{message}"

  defp error_message({:http_response_headers_expression_error, detail}),
    do: "The bfw:httpResponseHeaders expression failed: #{detail}"

  defp truncate_body(body) when is_binary(body) do
    if String.valid?(body),
      do: String.slice(body, 0, @error_body_max_characters),
      else: "(#{byte_size(body)} bytes of binary data)"
  end

  defp truncate_body(body) do
    case Jason.encode(body) do
      {:ok, encoded} -> String.slice(encoded, 0, @error_body_max_characters)
      {:error, _reason} -> "(not representable as text)"
    end
  end

  defp transport_failure(:econnrefused), do: "the connection was refused"
  defp transport_failure(:closed), do: "the connection was closed"
  defp transport_failure(:nxdomain), do: "the host name could not be resolved"
  defp transport_failure(reason) when is_atom(reason), do: "the transport failed (#{reason})"
  defp transport_failure(_reason), do: "the transport failed"

  defp client_failure(%{reason: reason}) when tuple_size(reason) > 0 and is_atom(elem(reason, 0)),
    do: "the HTTP client rejected the request (#{elem(reason, 0)})"

  defp client_failure(%{reason: reason}) when is_atom(reason),
    do: "the HTTP client rejected the request (#{reason})"

  defp client_failure(%{__struct__: module}), do: "the HTTP client failed (#{inspect(module)})"

  # -- Validation (synchronous, runs in handle_enter) -------------------------

  defp validate_url(type_data, flow_node_id) do
    case type_data.http_url do
      nil -> {:error, {:http_handler_missing_url, flow_node_id}}
      "" -> {:error, {:http_handler_missing_url, flow_node_id}}
      url -> {:ok, url}
    end
  end

  defp validate_method(type_data) do
    method = type_data.http_method || @default_method

    if method in @valid_methods do
      {:ok, method}
    else
      {:error, {:http_handler_invalid_method, method}}
    end
  end

  defp evaluate_body(type_data, flow_node, token, handler_context) do
    case type_data.http_body do
      nil ->
        {:ok, nil}

      "" ->
        {:ok, nil}

      expression ->
        evaluate_feel(expression, flow_node, token, handler_context, :http_body_expression_error)
    end
  end

  defp evaluate_auth_header(type_data, flow_node, token, handler_context) do
    case type_data.http_auth_header do
      nil ->
        {:ok, nil}

      "" ->
        {:ok, nil}

      expression ->
        expression
        |> evaluate_feel(flow_node, token, handler_context, :http_auth_expression_error)
        |> require_header_text()
    end
  end

  defp require_header_text({:ok, value}) when is_binary(value) do
    if String.contains?(value, ["\r", "\n", "\0"]) do
      {:error,
       {:http_auth_expression_error,
        "the expression evaluated to text containing a line break or NUL character"}}
    else
      {:ok, value}
    end
  end

  defp require_header_text({:ok, value}) when is_number(value), do: {:ok, to_string(value)}

  defp require_header_text({:ok, nil}), do: {:ok, nil}

  defp require_header_text({:ok, _value}),
    do:
      {:error,
       {:http_auth_expression_error, "the expression did not evaluate to a string or number"}}

  defp require_header_text(error), do: error

  defp evaluate_feel(expression, flow_node, token, handler_context, error_key) do
    context = build_feel_context(flow_node, token, handler_context)

    case BfwEngine.Expressions.eval(expression, context) do
      {:ok, result} -> {:ok, result}
      {:error, details} -> {:error, {error_key, details}}
    end
  rescue
    error -> {:error, {error_key, Exception.message(error)}}
  end

  # -- HTTP execution (runs in spawned Task) ----------------------------------

  defp execute_request(req_opts, url, type_data, flow_node, token, handler_context) do
    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: resp_body, headers: resp_headers}}
      when status >= 200 and status < 300 ->
        build_success_output(
          resp_body,
          resp_headers,
          type_data,
          flow_node,
          token,
          handler_context
        )

      {:ok, %Req.Response{status: status, body: resp_body}} ->
        {:error, {:http_error, status, resp_body}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, {:http_timeout, url}}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:http_connection_failed, url, transport_failure(reason)}}

      {:error, exception} ->
        {:error, {:http_connection_failed, url, client_failure(exception)}}
    end
  rescue
    exception -> {:error, {:http_request_failed, url, Exception.message(exception)}}
  catch
    kind, _value -> {:error, {:http_request_failed, url, "the HTTP client stopped with #{kind}"}}
  end

  defp build_req_opts(url, method, body, auth_header) do
    method_atom = method |> String.downcase() |> String.to_existing_atom()

    opts = [
      url: url,
      method: method_atom,
      receive_timeout: @request_timeout_ms
    ]

    opts =
      if body do
        Keyword.put(opts, :json, body)
      else
        opts
      end

    opts =
      if auth_header do
        Keyword.put(opts, :headers, [{"authorization", to_string(auth_header)}])
      else
        opts
      end

    extra = Application.get_env(:engine_plugins, :http_req_options, [])
    Keyword.merge(opts, extra)
  end

  defp build_success_output(resp_body, resp_headers, type_data, flow_node, token, handler_context) do
    with {:ok, output} <-
           apply_response_headers(
             resp_body,
             resp_headers,
             type_data,
             flow_node,
             token,
             handler_context
           ),
         :ok <- PayloadCap.check(output) do
      {:ok, output}
    else
      {:error, :payload_too_large, _details} -> {:error, :payload_too_large}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_response_headers(output, resp_headers, type_data, flow_node, token, handler_context) do
    case evaluate_response_headers(type_data, resp_headers, flow_node, token, handler_context) do
      {:ok, nil} -> {:ok, output}
      {:ok, header_data} -> {:ok, merge_output(output, header_data)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp evaluate_response_headers(type_data, resp_headers, flow_node, token, handler_context) do
    case type_data.http_response_headers do
      nil ->
        {:ok, nil}

      "" ->
        {:ok, nil}

      expression ->
        headers_map = normalize_headers(resp_headers)

        context =
          build_feel_context(flow_node, token, handler_context)
          |> Map.put("responseHeaders", headers_map)

        case BfwEngine.Expressions.eval(expression, context) do
          {:ok, result} -> {:ok, result}
          {:error, details} -> {:error, {:http_response_headers_expression_error, details}}
        end
    end
  rescue
    error -> {:error, {:http_response_headers_expression_error, Exception.message(error)}}
  end

  defp normalize_headers(headers) when is_map(headers) do
    Map.new(headers, fn {key, value} ->
      normalized_value = if is_list(value), do: List.first(value), else: value
      {String.downcase(to_string(key)), to_string(normalized_value)}
    end)
  end

  defp merge_output(output, header_data) when is_map(output) and is_map(header_data) do
    Map.merge(output, header_data)
  end

  defp merge_output(output, header_data) do
    %{"body" => output, "headers" => header_data}
  end

  defp build_feel_context(_flow_node, token, handler_context) do
    handler_context
    |> FeelContext.from_handler_context(token.payload || %{})
    |> FeelContext.to_feel_scope()
  end
end
