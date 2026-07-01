---
name: database-migrations
description: >-
  Apply the project's single-migration database strategy for ThomasTheDaemonEngine.
  Use when adding columns, tables, indexes, or constraints to the engine's PostgreSQL
  schema, or when creating Ecto migrations.
---

# Database Migrations — One Migration, One Truth

## Context

ThomasTheDaemonEngine is in early pre-alpha. There are no production deployments and
no data to migrate. The project follows a **single initial migration** policy, as
documented in `docs/Philosophy.md` under "One Migration, One Truth".

## The Rule

**Never create a new migration file.** Instead, edit the existing initial migration
in place:

```
apps/peripheral_persistence/priv/repo/migrations/20260501110314_create_initial_schema.exs
```

This is the **only** migration file that should exist. All schema changes — new
columns, new tables, new indexes, new constraints — are added directly to this file.

## How to Apply Schema Changes

1. **Open the initial migration** at the path above.
2. **Add your change** in the appropriate section (the file is organized by domain):
   - Section 1: Ash/Postgres extension functions
   - Section 2: Catalog tables (`processes`, `process_versions`)
   - Section 3: Execution tables (`process_instances`, `flow_node_instances`, `gateway_pending_arrivals`)
   - Section 4: Audit tables (`process_instance_events`, `data_objects`, `data_object_writes`)
   - Section 5: JSONB compression settings
3. **Update the `down/0` function** to reverse your change (drop the column/table/index).
4. **Update the `@moduledoc`** "Contains:" list if you added a new table or section.
5. **Reset the test database**: `MIX_ENV=test mix ecto.reset`
6. **Run the quality gate**: `mix quality`

## Example: Adding a Column

To add `error_info :map` to `flow_node_instances`:

In `up/0`, inside the existing `create table(:flow_node_instances, ...)` block:

```elixir
add :error_info, :map
```

In `down/0`, no extra step needed — `drop table(:flow_node_instances)` already
removes the entire table including all columns.

## Example: Adding a Constraint

Add the constraint immediately after the `create table(...)` block it belongs to:

```elixir
create constraint(:flow_node_instances, :flow_node_instances_my_constraint,
         check: "some_column IS NOT NULL"
       )
```

In `down/0`, add a `drop_if_exists constraint(...)` **before** the corresponding
`drop table(...)` call.

## What NOT to Do

- Do **not** run `mix ash_postgres.generate_migrations` or `mix ecto.gen.migration`.
- Do **not** create files like `20260507_add_something.exs`.
- Do **not** add migration files for incremental schema changes.

## When This Policy Ends

This policy applies during **Phase 0 and Phase 1** (pre-alpha). Once the engine
reaches production users with real data, proper incremental migrations become
essential. The transition point will be explicitly communicated and this skill
updated accordingly.
