defmodule Examples.Plugins.GithubBpmnDeployer.GithubClient do
  @moduledoc """
  Minimal HTTP client for the GitHub Contents API.

  Uses `:httpc` from Erlang/OTP so the example has zero external HTTP
  dependencies.  Production plugins would typically swap this for `Req`,
  `Finch`, or `Tesla`.

  All functions accept a `config` map built by `build_config/0` from
  environment variables.
  """

  require Logger

  @type config :: %{
          owner: String.t(),
          repo: String.t(),
          branch: String.t(),
          path: String.t(),
          token: String.t(),
          api_base_url: String.t()
        }

  @type file_entry :: %{name: String.t(), download_url: String.t()}

  @user_agent ~c"ThomasTheDaemonEngine-GithubBpmnDeployer/1.0"

  @doc """
  Reads GitHub configuration from environment variables.

  Required: `GITHUB_BPMN_REPO_OWNER`, `GITHUB_BPMN_REPO_NAME`, `GITHUB_ACCESS_TOKEN`.
  Optional: `GITHUB_BPMN_BRANCH` (default `main`), `GITHUB_BPMN_PATH` (default empty),
  `GITHUB_API_BASE_URL` (default `https://api.github.com`).
  """
  @spec build_config() :: config()
  def build_config do
    %{
      owner: System.fetch_env!("GITHUB_BPMN_REPO_OWNER"),
      repo: System.fetch_env!("GITHUB_BPMN_REPO_NAME"),
      branch: System.get_env("GITHUB_BPMN_BRANCH", "main"),
      path: System.get_env("GITHUB_BPMN_PATH", ""),
      token: System.fetch_env!("GITHUB_ACCESS_TOKEN"),
      api_base_url: System.get_env("GITHUB_API_BASE_URL", "https://api.github.com")
    }
  end

  @doc """
  Lists `.bpmn` files in the configured repository directory.

  Calls `GET /repos/:owner/:repo/contents/:path?ref=:branch` and filters
  for entries whose `name` ends with `.bpmn` and have a non-nil
  `download_url` (excludes submodules and LFS pointers).

  Returns `{:ok, [file_entry]}` or `{:error, reason}`.
  """
  @spec list_bpmn_files(config()) :: {:ok, [file_entry()]} | {:error, term()}
  def list_bpmn_files(config) do
    path_segment =
      if config.path == "",
        do: "",
        else: "/#{URI.encode(config.path, &URI.char_unreserved?/1)}"

    encoded_branch = URI.encode(config.branch, &URI.char_unreserved?/1)

    url =
      "#{config.api_base_url}/repos/#{config.owner}/#{config.repo}" <>
        "/contents#{path_segment}?ref=#{encoded_branch}"

    case http_get_json(url, config.token) do
      {:ok, entries} when is_list(entries) ->
        bpmn_files =
          entries
          |> Enum.filter(fn entry ->
            entry["type"] == "file" and
              String.ends_with?(entry["name"] || "", ".bpmn") and
              not is_nil(entry["download_url"])
          end)
          |> Enum.map(fn entry ->
            %{name: entry["name"], download_url: entry["download_url"]}
          end)

        {:ok, bpmn_files}

      {:ok, %{"message" => message}} ->
        {:error, {:github_api_error, message}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Downloads raw file content from the given URL.

  Returns `{:ok, body_string}` or `{:error, reason}`.
  """
  @spec download_raw(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def download_raw(url, token) do
    headers = [
      {~c"User-Agent", @user_agent}
      | authorization_headers(token)
    ]

    :ok = ensure_inets_started()

    case :httpc.request(:get, {String.to_charlist(url), headers}, [{:ssl, ssl_options()}], []) do
      {:ok, {{_http_version, status_code, _reason_phrase}, _response_headers, body}}
      when status_code in 200..299 ->
        {:ok, List.to_string(body)}

      {:ok, {{_http_version, status_code, reason_phrase}, _response_headers, _body}} ->
        {:error, {:http_error, status_code, List.to_string(reason_phrase)}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp http_get_json(url, token) do
    headers = [
      {~c"Accept", ~c"application/vnd.github+json"},
      {~c"User-Agent", @user_agent}
      | authorization_headers(token)
    ]

    :ok = ensure_inets_started()

    case :httpc.request(:get, {String.to_charlist(url), headers}, [{:ssl, ssl_options()}], []) do
      {:ok, {{_http_version, status_code, _reason_phrase}, _response_headers, body}}
      when status_code in 200..299 ->
        Jason.decode(List.to_string(body))

      {:ok, {{_http_version, status_code, _reason_phrase}, _response_headers, body}} ->
        case Jason.decode(List.to_string(body)) do
          {:ok, decoded} -> {:ok, decoded}
          _error -> {:error, {:http_error, status_code, List.to_string(body)}}
        end

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp authorization_headers(token) do
    [{~c"Authorization", String.to_charlist("Bearer #{token}")}]
  end

  defp ssl_options do
    [verify: :verify_peer, cacerts: :public_key.cacerts_get(), depth: 3]
  end

  defp ensure_inets_started do
    {:ok, _apps} = Application.ensure_all_started(:inets)
    :ok
  end
end
