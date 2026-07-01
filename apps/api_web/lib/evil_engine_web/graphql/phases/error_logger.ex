defmodule EvilEngineWeb.Graphql.Phases.ErrorLogger do
  @moduledoc """
  Absinthe phase that logs GraphQL errors for the audit trail.

  Inserted at the end of the execution pipeline by `PipelineModifier`,
  after `Phase.Document.Result`. Inspects the final result and logs any
  errors at `:warning` level. The phase is transparent — it never
  modifies the blueprint or the result.
  """

  use Absinthe.Phase

  require Logger

  @impl Absinthe.Phase
  def run(blueprint, _options \\ []) do
    case blueprint.result do
      %{errors: errors} when is_list(errors) and errors != [] ->
        log_graphql_errors(errors)

      _ ->
        :ok
    end

    {:ok, blueprint}
  end

  defp log_graphql_errors(errors) do
    messages = Enum.map(errors, &extract_message/1)

    Logger.warning("GraphQL errors: #{Enum.join(messages, "; ")}",
      graphql_error_count: length(errors)
    )
  end

  defp extract_message(%{message: message}) when is_binary(message), do: message
  defp extract_message(error), do: inspect(error)
end
