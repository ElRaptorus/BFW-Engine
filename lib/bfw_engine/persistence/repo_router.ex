defmodule BfwEngine.Persistence.RepoRouter do
  @moduledoc """
  Routes Ash resource operations to the appropriate Ecto Repo based
  on the operation type.

  - `:read` operations → `ReadRepo` (separate read pool)
  - `:mutate` operations → `Repo` (write pool)

  In test mode, all operations go through `Repo` because
  `Ecto.Adapters.SQL.Sandbox` uses per-repo transaction isolation —
  data written through `Repo` is invisible to `ReadRepo`.

  Used as the `repo` callback in all Ash resource `postgres do` blocks:

      postgres do
        repo &BfwEngine.Persistence.RepoRouter.repo/2
      end
  """

  @read_repo if Mix.env() == :test,
               do: BfwEngine.Persistence.Repo,
               else: BfwEngine.Persistence.ReadRepo

  @spec repo(Ash.Resource.t(), :read | :mutate) :: module()
  def repo(_resource, :read), do: @read_repo
  def repo(_resource, :mutate), do: BfwEngine.Persistence.Repo
end
