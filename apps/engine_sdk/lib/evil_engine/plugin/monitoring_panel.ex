defmodule EvilEngine.Plugin.MonitoringPanel do
  @moduledoc """
  Contributes a fragment to the admin HTML page.

  Many allowed; each registration adds one panel.
  """

  @callback render(assigns :: map()) :: term()
  @callback panel_title() :: String.t()
end
