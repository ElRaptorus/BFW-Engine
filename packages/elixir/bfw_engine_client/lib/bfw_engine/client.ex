defmodule BfwEngine.Client do
  @moduledoc """
  Entry point for the standalone Elixir client of the Bifrost Forge World
  Engine.

  Builds a lightweight, immutable struct that carries the Engine's HTTP base
  URL and the bearer token used to authenticate every request. The struct is
  passed explicitly to every resource module (`BfwEngine.Client.Processes`,
  `BfwEngine.Client.ProcessInstances`, `BfwEngine.Client.UserTasks`,
  `BfwEngine.Client.ManualTasks`, `BfwEngine.Client.Events`,
  `BfwEngine.Client.AdhocSubprocesses`, and `BfwEngine.Client.Graphql`) —
  there is no process, no application supervision tree, and no hidden
  global state.

  ## Example

      client = BfwEngine.Client.new(base_url: "http://localhost:4100", token: "eyJ...")
      {:ok, processes} = BfwEngine.Client.Processes.list(client)
  """

  alias BfwEngine.Client.Error

  defstruct [:base_url, :token, :req_options]

  @typedoc """
  A resolvable bearer token: either the raw string, or a zero-arity function
  invoked per request so a caller can supply a fresh token (for example, a
  per-user JWT refreshed on every call).
  """
  @type token :: String.t() | (-> String.t()) | nil

  @type t :: %__MODULE__{
          base_url: String.t(),
          token: token(),
          req_options: keyword()
        }

  @doc """
  Builds a new client.

  ## Options

    * `:base_url` (required) - the Engine's HTTP base URL, e.g.
      `"http://localhost:4100"`.
    * `:token` - a bearer token string, or a zero-arity function called per
      request to resolve a fresh token. Defaults to `nil` (no
      `Authorization` header).
    * `:req_options` - extra options merged into every `Req.Request` built
      for this client (timeouts, retries, custom finch pool, and so on).
      Requests are not retried unless `:retry` is set here, matching the
      TypeScript client.
  """
  @spec new(keyword()) :: t()
  def new(options) do
    base_url =
      case Keyword.fetch(options, :base_url) do
        {:ok, base_url} -> base_url
        :error -> raise ArgumentError, "BfwEngine.Client.new/1 requires the :base_url option"
      end

    %__MODULE__{
      base_url: base_url,
      token: Keyword.get(options, :token),
      req_options: Keyword.get(options, :req_options, [])
    }
  end

  @doc false
  @spec request(t(), atom(), String.t(), keyword()) ::
          {:ok, term()} | {:error, Error.t() | Exception.t()}
  def request(%__MODULE__{} = client, method, path, options \\ []) do
    [method: method, url: path, base_url: client.base_url, retry: false]
    |> Keyword.merge(client.req_options)
    |> Keyword.merge(options)
    |> put_authorization_header(client.token)
    |> Req.new()
    |> Req.request()
    |> handle_response()
  end

  defp put_authorization_header(request_options, nil), do: request_options

  defp put_authorization_header(request_options, token) do
    Keyword.update(request_options, :headers, [authorization_header(token)], fn headers ->
      [authorization_header(token) | Enum.to_list(headers)]
    end)
  end

  defp authorization_header(token) when is_binary(token),
    do: {"authorization", "Bearer " <> token}

  defp authorization_header(token) when is_function(token, 0), do: authorization_header(token.())

  defp handle_response({:ok, %Req.Response{status: status, body: body}})
       when status in 200..299 do
    {:ok, body}
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    {:error, Error.from_response(status, body)}
  end

  defp handle_response({:error, exception}), do: {:error, exception}
end
