defmodule Examples.EventSinks.WebhookForwarder.WebhookSink do
  @moduledoc """
  Forwards each accepted engine event to an HTTP endpoint as JSON.

  `filter_types` in `init/1` restricts which `event.__struct__` values are accepted.
  Because `accepts?/1` is stateless in the behaviour API, the filter list is stored
  in the sink worker process dictionary when `init/1` runs (one registration per worker).
  """

  @behaviour EvilEngine.Plugin.EventSink

  @filter_types_key :examples_webhook_forwarder_sink_filter_types

  @doc "Stores URL, headers, and optional type filter in process state for later delivery calls."
  @impl true
  def init(options) do
    url = Keyword.fetch!(options, :url)
    headers = Keyword.get(options, :headers, [{"content-type", "application/json"}])
    filter_types = Keyword.get(options, :filter_types)
    deliver_payload = Keyword.get(options, :deliver_payload, &default_deliver_payload/3)

    Process.put(@filter_types_key, filter_types)

    {:ok,
     %{
       url: url,
       headers: headers,
       deliver_payload: deliver_payload
     }}
  end

  @doc "Applies the optional event struct filter stored during init for this worker."
  @impl true
  def accepts?(event) do
    case Process.get(@filter_types_key) do
      types when types in [nil, []] ->
        true

      filter_list when is_list(filter_list) ->
        event.__struct__ in filter_list
    end
  end

  @doc "Encodes the event as JSON and invokes the configured delivery function."
  @impl true
  def handle_event(event, state) do
    payload_map = event_to_webhook_map(event)
    json_body = Jason.encode!(payload_map)
    state.deliver_payload.(state.url, state.headers, json_body)
    {:ok, state}
  end

  @doc "Clears process dictionary filter state when the sink shuts down."
  @impl true
  def handle_shutdown(_state) do
    Process.delete(@filter_types_key)
    :ok
  end

  defp event_to_webhook_map(event) do
    field_map =
      event
      |> Map.from_struct()
      |> Enum.into(%{}, fn {field_name, field_value} ->
        {Atom.to_string(field_name), json_ready_value(field_value)}
      end)

    Map.put(field_map, "type", struct_type_name(event))
  end

  defp struct_type_name(event) do
    event.__struct__
    |> Module.split()
    |> Enum.join(".")
  end

  defp json_ready_value(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp json_ready_value(value) when is_atom(value), do: Atom.to_string(value)

  defp json_ready_value(value) when is_list(value), do: Enum.map(value, &json_ready_value/1)

  defp json_ready_value(value) when is_map(value) and not is_struct(value) do
    Enum.into(value, %{}, fn {key, nested_value} ->
      {json_ready_map_key(key), json_ready_value(nested_value)}
    end)
  end

  defp json_ready_value(value), do: value

  defp json_ready_map_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_ready_map_key(key) when is_binary(key), do: key

  defp default_deliver_payload(_url, _headers, _json_body) do
    # TODO: replace with :httpc.request(:post, {String.to_charlist(url), headers, 'application/json', String.to_charlist(json_body)}, [], [])
    :ok
  end
end
