defmodule EvilEngine.Plugin.TimerSource do
  @moduledoc """
  Custom timer evaluation for non-standard timer types.

  **Not implemented in v1.** Registration is accepted and ignored at
  runtime. Core timers already parse ISO 8601 date, duration, and cycle
  expressions. Do not depend on this behaviour being invoked.

  Unique per type (`date`/`duration`/`cycle`/custom) if this capability
  is ever wired.
  """

  @callback timer_type() :: atom()
  @callback evaluate(definition :: String.t(), context :: map()) ::
              {:ok, DateTime.t()} | {:error, term()}
end
