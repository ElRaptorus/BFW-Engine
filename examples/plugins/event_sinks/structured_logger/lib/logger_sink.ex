defmodule Examples.EventSinks.StructuredLogger.LoggerSink do
  @moduledoc """
  Writes one JSON object per line to standard output or a file.

  Zero third-party dependencies beyond what the engine already uses (`Jason`).
  """

  @behaviour EvilEngine.Plugin.EventSink

  alias EvilEngine.Types.Event

  @doc "Opens stdout or an append-only file as the sink output based on registration options."
  @impl true
  def init(options) do
    case Keyword.fetch!(options, :output) do
      :stdout ->
        {:ok, %{output_target: :stdio}}

      file_path when is_binary(file_path) ->
        case File.open(file_path, [:append, :utf8]) do
          {:ok, io_device} -> {:ok, %{output_target: {:file, io_device}}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc "Accepts every engine event so the example sink can log the full stream."
  @impl true
  def accepts?(_event), do: true

  @doc "Serializes one JSON log line for the event and writes it to the configured output."
  @impl true
  def handle_event(event, state) do
    line_map = log_line_map(event)
    json_line = Jason.encode!(line_map) <> "\n"
    write_json_line(state, json_line)
    {:ok, state}
  end

  @doc "Closes a file output device when present, or returns without work when the sink targets standard output."
  @impl true
  def handle_shutdown(%{output_target: {:file, io_device}}) do
    File.close(io_device)
    :ok
  end

  @impl true
  def handle_shutdown(_state), do: :ok

  defp log_line_map(event) do
    base = %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      severity: severity_for(event),
      event_type: event_type_name(event)
    }

    field_entries =
      event
      |> Map.from_struct()
      |> Enum.into(%{}, fn {field_name, field_value} ->
        {Atom.to_string(field_name), json_ready_value(field_value)}
      end)

    Map.merge(base, field_entries)
  end

  defp severity_for(%Event.SinkFailed{}), do: "error"
  defp severity_for(%Event.PluginQuarantined{}), do: "error"
  defp severity_for(%Event.EngineOverloaded{}), do: "warning"
  defp severity_for(_event), do: "info"

  defp event_type_name(event) do
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

  defp write_json_line(%{output_target: :stdio}, json_line) do
    IO.write(:stdio, json_line)
  end

  defp write_json_line(%{output_target: {:file, io_device}}, json_line) do
    IO.write(io_device, json_line)
  end
end
