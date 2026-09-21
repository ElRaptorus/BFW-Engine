defmodule BfwEngine.EngineFacade.Decisions do
  @moduledoc """
  Runtime namespace for Decision Model catalog and evaluation operations.

  Mirrors the `EngineFacade.Processes` pattern. Each field is a closure
  wired by the Loader to the corresponding `BfwEngine.Api` function
  with the plugin's synthetic identity pre-injected.

  ## Closures

  | Field | Arity | Description |
  |---|---|---|
  | `list` | 0 | List all decision definitions |
  | `get` | 1 | Get a single decision definition by model ID |
  | `get_latest_version` | 1 | Return the latest non-deleted version for a definition |
  | `validate` | 1 | Parse and validate DMN XML without persisting |
  | `deploy` | 1 | Deploy a batch of DMN XML sources |
  | `evaluate` | 3 | Evaluate a single decision ad-hoc |
  | `evaluate_by_version` | 4 | Evaluate a specific version of a decision |
  | `evaluate_service` | 4 | Evaluate a DMN Decision Service ad-hoc |
  | `get_versions` | 1 | List all non-deleted versions for a definition |
  | `get_xml` | 1 | Retrieve the raw DMN XML for the latest version |
  | `enable` | 1 | Enable a decision definition |
  | `disable` | 1 | Disable a decision definition |
  | `delete_version` | 2 | Soft-delete a specific decision version |
  | `undeploy` | 1 | Soft-delete all versions for a definition |
  """

  @type t :: %__MODULE__{
          list: (-> {:ok, list()} | {:error, term()}),
          get: (String.t() -> {:ok, struct()} | :not_found),
          get_latest_version: (String.t() -> {:ok, struct()} | {:error, :no_active_version}),
          validate: (String.t() -> {:ok, struct()} | {:error, term()}),
          deploy: ([String.t()] -> {:ok, [map()]} | {:error, term()}),
          evaluate: (String.t(), map(), keyword() -> {:ok, struct()} | {:error, term()}),
          evaluate_by_version: (String.t(), String.t(), map(), keyword() ->
                                  {:ok, struct()} | {:error, term()}),
          evaluate_service: (String.t(), String.t(), map(), keyword() ->
                               {:ok, struct()} | {:error, term()}),
          get_versions: (String.t() -> {:ok, list()} | {:error, term()}),
          get_xml: (String.t() -> {:ok, String.t()} | {:error, term()}),
          enable: (String.t() -> {:ok, struct()} | {:error, term()}),
          disable: (String.t() -> {:ok, struct()} | {:error, term()}),
          delete_version: (String.t(), String.t() -> {:ok, struct()} | {:error, term()}),
          undeploy: (String.t() -> :ok | {:error, term()})
        }

  defstruct list: &__MODULE__.noop_0/0,
            get: &__MODULE__.noop_1/1,
            get_latest_version: &__MODULE__.noop_1/1,
            validate: &__MODULE__.noop_1/1,
            deploy: &__MODULE__.noop_1/1,
            evaluate: &__MODULE__.noop_3/3,
            evaluate_by_version: &__MODULE__.noop_4/4,
            evaluate_service: &__MODULE__.noop_4/4,
            get_versions: &__MODULE__.noop_1/1,
            get_xml: &__MODULE__.noop_1/1,
            enable: &__MODULE__.noop_1/1,
            disable: &__MODULE__.noop_1/1,
            delete_version: &__MODULE__.noop_2/2,
            undeploy: &__MODULE__.noop_1/1

  @doc false
  @spec noop_0() :: {:error, :not_wired}
  def noop_0, do: {:error, :not_wired}

  @doc false
  @spec noop_1(term()) :: {:error, :not_wired}
  def noop_1(_arg), do: {:error, :not_wired}

  @doc false
  @spec noop_2(term(), term()) :: {:error, :not_wired}
  def noop_2(_arg1, _arg2), do: {:error, :not_wired}

  @doc false
  @spec noop_3(term(), term(), term()) :: {:error, :not_wired}
  def noop_3(_arg1, _arg2, _arg3), do: {:error, :not_wired}

  @doc false
  @spec noop_4(term(), term(), term(), term()) :: {:error, :not_wired}
  def noop_4(_arg1, _arg2, _arg3, _arg4), do: {:error, :not_wired}
end
