defmodule BfwEngineWeb.Http.ErrorJSON do
  @moduledoc """
  Generic JSON error renderer for unhandled Phoenix exceptions.

  Uses the same `{error, message}` shape as `BfwEngineWeb.Http.ErrorResponse`
  so SDK error mappers work consistently across all HTTP error paths.
  """

  def render(template, _assigns) do
    {error_code, message} = template_to_error(template)
    %{error: error_code, message: message}
  end

  defp template_to_error("404.json"), do: {"not_found", "Not Found"}
  defp template_to_error("500.json"), do: {"internal_error", "Internal Server Error"}
  defp template_to_error("400.json"), do: {"bad_request", "Bad Request"}
  defp template_to_error("406.json"), do: {"not_acceptable", "Not Acceptable"}
  defp template_to_error("413.json"), do: {"payload_too_large", "Request Entity Too Large"}
  defp template_to_error("415.json"), do: {"unsupported_media_type", "Unsupported Media Type"}

  defp template_to_error(template) do
    message = Phoenix.Controller.status_message_from_template(template)
    {"internal_error", message}
  end
end
