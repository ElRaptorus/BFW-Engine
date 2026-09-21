defmodule Mix.Tasks.Bfw.MintToken do
  @moduledoc """
  Mint a signed HS256 JWT for local development and API testing.

  The token is printed to stdout, ready to copy-paste into Postman or curl:

      curl -H "Authorization: Bearer $(mix bfw.mint_token)" http://localhost:4000/stats

  ## Options

      --sub, -s       Subject claim (default: "dev-user")
      --roles, -r     Comma-separated roles (default: "admin")
      --groups, -g    Comma-separated groups (default: "")
      --exp, -e       Token lifetime with unit suffix (default: "24h")
                      Supported units:
                        8s  → 8 seconds
                        8m  → 8 minutes
                        8   → 8 hours (bare number = hours)
                        8h  → 8 hours
                        8d  → 8 days
      --full, -f      Include all supported capability claims at maximum privilege
      --claim         Arbitrary claim as KEY=VALUE (repeatable, applied after --full)
      --help, -h      Print this help

  ## Secret resolution

  The signing secret is resolved in order:

  1. `BFE_JWT_HS256_SECRET` environment variable
  2. Application config `:api_auth, :hs256_secret`
  3. The default dev secret `AveOmnissiah_FromTheHolyForgesOfMars_NotAProductionSecret_Mechanicus!!`

  Both the env var and the default match the docker-compose.yml default
  so tokens work out of the box.

  ## Claim value coercion

  Values passed via `--claim KEY=VALUE` are coerced: `"true"` and `"false"`
  become boolean `true`/`false`, matching how controllers check boolean-gated
  claims (e.g. `identity.claims["deploy_bpmn"] == true`). All other values
  remain strings.

  Lane claims **must** be the strings `"read"` or `"write"`:

      mix bfw.mint_token --claim lane:Management=write

  `--claim lane:Management=true` is coerced to boolean `true`, which the
  engine treats as garbage (fail closed — no observe, no act).

  `--full` does **not** include `observe_all`. Mint an observer with:

      mix bfw.mint_token --claim observe_all=true

  ## Examples

      # Quick admin token (24h, the default)
      mix bfw.mint_token

      # Full-privilege token with every supported *write* claim (Studio operator)
      mix bfw.mint_token --full

      # Token valid for 7 days
      mix bfw.mint_token --exp 7d

      # Token valid for 30 minutes
      mix bfw.mint_token --exp 30m

      # Custom operator with 1-hour expiry
      mix bfw.mint_token --sub operator-1 --roles admin,viewer --exp 1h

      # Arbitrary extra claims
      mix bfw.mint_token --sub qa-bot --claim tenant_id=acme --claim env=staging

      # Boolean claim (correctly stored as boolean true, not string "true")
      mix bfw.mint_token --claim deploy_bpmn=true

      # Lane write (Studio clerk on Management)
      mix bfw.mint_token --claim lane:default=write --claim lane:Management=write

      # Unbounded observer (see everything, act on nothing)
      mix bfw.mint_token --claim observe_all=true
  """

  use Mix.Task

  @shortdoc "Mint a signed HS256 JWT for local dev / API testing"

  @default_secret "AveOmnissiah_FromTheHolyForgesOfMars_NotAProductionSecret_Mechanicus!!"
  @default_sub "dev-user"
  @default_roles "admin"
  @default_exp "24h"

  @full_privilege_claims %{
    "deploy_bpmn" => true,
    "deploy_dmn" => true,
    "delete_bpmn" => true,
    "delete_dmn" => true,
    "abort_process_instance" => "all",
    "retry_process_instance" => "all",
    "delete_process_instance" => "all",
    "trigger_message" => "all",
    "trigger_signal" => "all",
    "trigger_escalation" => true,
    "zeeky_boogie_doog" => true,
    "lane:default" => "write"
  }

  @switches [
    sub: :string,
    roles: :string,
    groups: :string,
    exp: :string,
    full: :boolean,
    help: :boolean
  ]
  @aliases [s: :sub, r: :roles, g: :groups, e: :exp, f: :full, h: :help]

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)

    if Keyword.get(opts, :help, false) do
      print_help()
    else
      mint(opts, args)
    end
  end

  defp mint(opts, args) do
    full_claims = if Keyword.get(opts, :full, false), do: @full_privilege_claims, else: %{}
    extra_claims = parse_claim_flags(args)

    exp_input = Keyword.get(opts, :exp, @default_exp)

    case parse_duration(exp_input) do
      {:ok, exp_seconds} ->
        sign_and_print(opts, exp_seconds, full_claims, extra_claims)

      {:error, message} ->
        Mix.shell().error(message)
        Mix.shell().error("")
        print_usage()
    end
  end

  defp sign_and_print(opts, exp_seconds, full_claims, extra_claims) do
    secret =
      System.get_env("BFE_JWT_HS256_SECRET") ||
        Application.get_env(:api_auth, :hs256_secret) ||
        @default_secret

    sub = Keyword.get(opts, :sub, @default_sub)
    roles = Keyword.get(opts, :roles, @default_roles) |> split_csv()
    groups = Keyword.get(opts, :groups, "") |> split_csv()

    now = DateTime.utc_now()
    expires_at = DateTime.add(now, exp_seconds)

    claims =
      %{
        "sub" => sub,
        "roles" => roles,
        "groups" => groups,
        "iat" => DateTime.to_unix(now),
        "exp" => DateTime.to_unix(expires_at)
      }
      |> Map.merge(full_claims)
      |> Map.merge(extra_claims)

    jwk = JOSE.JWK.from_oct(secret)
    {_, compact} = JOSE.JWT.sign(jwk, %{"alg" => "HS256"}, claims) |> JOSE.JWS.compact()

    Mix.shell().info(compact)

    Mix.shell().error(
      "  Token minted for \"#{sub}\" — expires #{format_datetime(expires_at)} (#{format_duration(exp_seconds)})"
    )
  end

  @doc false
  @spec parse_duration(String.t()) :: {:ok, pos_integer()} | {:error, String.t()}
  def parse_duration(input) do
    trimmed = String.trim(input)

    case Regex.run(~r/^(\d+)(s|m|h|d)?$/, trimmed) do
      [_, number_string, "s"] ->
        {:ok, String.to_integer(number_string)}

      [_, number_string, "m"] ->
        {:ok, String.to_integer(number_string) * 60}

      [_, number_string, "h"] ->
        {:ok, String.to_integer(number_string) * 3600}

      [_, number_string, "d"] ->
        {:ok, String.to_integer(number_string) * 86_400}

      [_, number_string] ->
        {:ok, String.to_integer(number_string) * 3600}

      nil ->
        {:error,
         "Invalid duration: \"#{trimmed}\". Expected a number with optional unit suffix (s, m, h, d)."}
    end
  end

  defp format_duration(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_duration(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m"
  defp format_duration(seconds) when seconds < 86_400, do: "#{div(seconds, 3600)}h"
  defp format_duration(seconds), do: "#{div(seconds, 86_400)}d"

  defp format_datetime(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")
  end

  defp print_help do
    Mix.shell().info(@moduledoc)
  end

  defp print_usage do
    Mix.shell().error("""
    Usage: mix bfw.mint_token [options]

    Duration format for --exp:
      8s  → 8 seconds       30m  → 30 minutes
      8   → 8 hours          8h  → 8 hours
      7d  → 7 days

    Run 'mix bfw.mint_token --help' for full documentation.
    """)
  end

  defp split_csv(""), do: []
  defp split_csv(string), do: string |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  defp parse_claim_flags(args) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.filter(fn [flag, _] -> flag == "--claim" end)
    |> Enum.reduce(%{}, fn [_, key_value], accumulator ->
      case String.split(key_value, "=", parts: 2) do
        [key, value] -> Map.put(accumulator, key, coerce_value(value))
        _ -> accumulator
      end
    end)
  end

  defp coerce_value("true"), do: true
  defp coerce_value("false"), do: false
  defp coerce_value(value), do: value

  @doc false
  def full_privilege_claims, do: @full_privilege_claims

  @doc false
  def coerce_claim_value(value), do: coerce_value(value)
end
