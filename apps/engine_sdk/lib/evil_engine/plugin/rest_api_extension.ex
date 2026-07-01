defmodule EvilEngine.Plugin.RestApiExtension do
  @moduledoc """
  Mounts additional REST/HTTP routes under a configured prefix.

  Registered via `facade.register_rest_api_extension.("/my-ext", MyPlugin.Router)`.
  """

  @callback router_module() :: module()
end
