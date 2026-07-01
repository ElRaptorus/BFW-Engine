defmodule EvilEngine.Execution.FniLifecycle.LifecycleResult do
  @moduledoc """
  Return struct from `FniLifecycle.finish/4`.

  Carries Data Object cache updates so the PI can apply them to its
  in-memory `data_object_cache` after the handler's Task sends the
  `{:fni_result, ...}` message.
  """

  @type t :: %__MODULE__{
          data_object_cache_updates: %{String.t() => term()}
        }

  defstruct data_object_cache_updates: %{}
end
