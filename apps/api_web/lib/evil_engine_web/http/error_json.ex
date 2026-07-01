defmodule EvilEngineWeb.Http.ErrorJSON do
  @moduledoc """
  Generic JSON error renderer for unhandled Phoenix exceptions.

  Uses the same `{error, message}` shape as `EvilEngineWeb.Http.ErrorResponse`
  so SDK error mappers work consistently across all HTTP error paths.
  """

  def render(template, _assigns) do
    {error_code, message} = template_to_error(template)
    %{error: error_code, message: message}
  end

  defp template_to_error("404.json"), do: {"not_found", "Not Found"}
  defp template_to_error("500.json"), do: {"internal_error", "Internal Server Error"}

  defp template_to_error(template) do
    message = Phoenix.Controller.status_message_from_template(template)
    {"internal_error", message}
  end
end
