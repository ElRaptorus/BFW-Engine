defmodule EvilEngine.Persistence.DataCase do
  @moduledoc """
  Ecto SQL Sandbox checkout for Ash/Repo-backed tests in `peripheral_persistence`.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox
  alias EvilEngine.Persistence.ReadRepo
  alias EvilEngine.Persistence.Repo

  using do
    quote do
      import EvilEngine.Persistence.DataCase
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
