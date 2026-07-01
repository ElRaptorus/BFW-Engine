defmodule EvilEngine.EngineFacade.Processes do
  @moduledoc """
  Runtime namespace for Process Model / Version catalog operations.

  Provides typed closures for reading, deploying, enabling/disabling,
  deleting, and starting processes. The `Loader` wires each closure to
  the corresponding `EvilEngine.Api` function with the plugin's
  synthetic identity pre-injected.
  """

  @type t :: %__MODULE__{
          get: (String.t() -> {:ok, struct()} | :not_found),
          get_latest_version: (String.t() -> {:ok, struct()} | {:error, :no_active_version}),
          deploy: ([map()] -> {:ok, [map()]} | {:error, term()}),
          enable: (String.t() -> {:ok, struct()} | {:error, term()}),
          disable: (String.t() -> {:ok, struct()} | {:error, term()}),
          delete_version: (String.t(), String.t() -> {:ok, struct()} | {:error, term()}),
          start: (keyword() -> {:ok, String.t()} | {:error, term()})
        }

  defstruct get: &__MODULE__.noop_1/1,
            get_latest_version: &__MODULE__.noop_1/1,
            deploy: &__MODULE__.noop_1/1,
            enable: &__MODULE__.noop_1/1,
            disable: &__MODULE__.noop_1/1,
            delete_version: &__MODULE__.noop_2/2,
            start: &__MODULE__.noop_1/1

  @doc false
  @spec noop_1(term()) :: {:error, :not_wired}
  def noop_1(_arg), do: {:error, :not_wired}

  @doc false
  @spec noop_2(term(), term()) :: {:error, :not_wired}
  def noop_2(_arg1, _arg2), do: {:error, :not_wired}
end
