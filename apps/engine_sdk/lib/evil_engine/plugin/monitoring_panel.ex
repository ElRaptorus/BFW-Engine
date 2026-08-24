defmodule EvilEngine.Plugin.MonitoringPanel do
  @moduledoc """
  Contributes a fragment to the admin HTML page.

  **Not implemented in v1.** Registration is accepted and ignored at
  runtime. There is no admin UI that renders these fragments. Do not
  depend on this behaviour being invoked.

  Many allowed; each registration would add one panel if this capability
  is ever wired.
  """

  @callback render(assigns :: map()) :: term()
  @callback panel_title() :: String.t()
end
