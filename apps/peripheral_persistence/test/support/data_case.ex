defmodule BfwEngine.Persistence.DataCase do
  @moduledoc """
  Ecto SQL Sandbox checkout for Ash/Repo-backed tests in `peripheral_persistence`.
  """

  use ExUnit.CaseTemplate

  alias BfwEngine.Persistence.ReadRepo
  alias BfwEngine.Persistence.Repo
  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      import BfwEngine.Persistence.DataCase
    end
  end

  setup _tags do
    :ok = Sandbox.checkout(Repo)
    Sandbox.mode(Repo, {:shared, self()})

    :ok = Sandbox.checkout(ReadRepo)
    Sandbox.mode(ReadRepo, {:shared, self()})

    :ok
  end
end
