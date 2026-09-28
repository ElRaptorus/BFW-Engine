defmodule BfwEngine.Client.Events do
  @moduledoc """
  Manual event triggers: messages, signals, escalations, and timers.
  """

  alias BfwEngine.Client
  alias BfwEngine.Client.Error
  alias BfwEngine.Client.Wire

  @doc """
  Publishes a message by name.

  ## Options

    * `:payload` - the message payload. Defaults to `%{}` on the wire.
    * `:correlation` - the correlation value matched against waiting
      subscriptions' `expected_correlation_value`.
  """
  @spec trigger_message(Client.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t() | Exception.t()}
  def trigger_message(%Client{} = client, message_name, options \\ []) do
    body =
      %{}
      |> Wire.put_if_present("payload", Keyword.get(options, :payload))
      |> Wire.put_if_present("correlation", Keyword.get(options, :correlation))

    Client.request(client, :post, "/messages/#{Wire.path_segment(message_name)}/trigger",
      json: body
    )
  end

  @doc """
  Broadcasts a signal by name. Signals carry no payload and no correlation.
  """
  @spec trigger_signal(Client.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t() | Exception.t()}
  def trigger_signal(%Client{} = client, signal_name) do
    Client.request(client, :post, "/signals/#{Wire.path_segment(signal_name)}/trigger", json: %{})
  end

  @doc """
  Injects a named escalation into waiting catchers engine-wide. Escalations
  carry no payload.
  """
  @spec trigger_escalation(Client.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t() | Exception.t()}
  def trigger_escalation(%Client{} = client, escalation_code) do
    Client.request(
      client,
      :post,
      "/escalations/#{Wire.path_segment(escalation_code)}/trigger",
      json: %{}
    )
  end

  @doc """
  Manually fires a waiting timer flow node instance.
  """
  @spec trigger_timer(Client.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t() | Exception.t()}
  def trigger_timer(%Client{} = client, flow_node_instance_id) do
    Client.request(
      client,
      :post,
      "/timer-events/#{Wire.path_segment(flow_node_instance_id)}/trigger",
      json: %{}
    )
  end
end
