ExUnit.start()

# Partitioned tables (messages, pending_messages, signals, pending_signals,
# data_object_writes, process_instance_events) require child partitions
# before any INSERT. Create them once before the test suite starts.
# See docs/architecture/common-pitfalls.md (Create partitions before INSERT).
{:ok, _} = EvilEngine.Persistence.Partitions.ensure_partitions()

# Truncate partitioned tables to remove stale data from previous crashed runs.
# The Ecto SQL Sandbox normally rolls back each test's data, but a VM crash
# (e.g. IDE crash) can leave orphaned rows that pollute subsequent test runs.
# Must checkout/checkin the sandbox connection explicitly since test_helper runs
# before any DataCase setup. Handle {:already, :owner} for direct `mix test` runs.
already_owner? =
  case Ecto.Adapters.SQL.Sandbox.checkout(EvilEngine.Persistence.Repo) do
    :ok -> false
    {:already, :owner} -> true
  end

for table <-
      ~w(pending_messages pending_signals messages signals data_object_writes process_instance_events) do
  EvilEngine.Persistence.Repo.query!("TRUNCATE #{table} CASCADE")
end

unless already_owner?, do: Ecto.Adapters.SQL.Sandbox.checkin(EvilEngine.Persistence.Repo)
