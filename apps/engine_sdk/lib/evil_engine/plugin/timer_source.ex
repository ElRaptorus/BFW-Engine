defmodule EvilEngine.Plugin.TimerSource do
  @moduledoc """
  Custom timer evaluation for non-standard timer types.

  Unique per type (`date`/`duration`/`cycle`/custom).
  """

  @callback timer_type() :: atom()
  @callback evaluate(definition :: String.t(), context :: map()) ::
              {:ok, DateTime.t()} | {:error, term()}
end
