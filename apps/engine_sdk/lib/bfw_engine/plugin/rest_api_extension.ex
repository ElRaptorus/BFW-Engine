defmodule BfwEngine.Plugin.RestApiExtension do
  @moduledoc """
  Mounts additional REST/HTTP routes under a configured prefix.

  Registered via `facade.register_rest_api_extension.("/my-ext", MyPlugin.Router)`.

  The registered handler is a **Plug** (`call/2`). A Phoenix router qualifies
  because it implements Plug. Identity is already on `conn.assigns.identity`;
  the engine does not apply engine claim policy (`deploy_bpmn`, etc.) to
  these routes.

  Reserved prefixes (`/processes`, `/decisions`, `/process-instances`,
  `/user-tasks`, `/timer-schedules`, `/timer-events`, `/messages`,
  `/signals`, `/escalations`, `/adhoc-subprocesses`, `/stats`, `/api`,
  `/admin`, `/health`, `/info`, `/metrics`) are rejected at registration
  with `{:error, :reserved_prefix}`.

  Plugin routes are **not** included in the OpenAPI spec — they are
  unknown at spec-author time.
  """

  @doc """
  Optional. Return the Plug or Phoenix router module that should receive
  the request. Defaults to the implementing module when omitted.
  The returned module must implement Plug (`init/1` and `call/2`).
  """
  @callback router_module() :: module()

  @optional_callbacks router_module: 0
end
