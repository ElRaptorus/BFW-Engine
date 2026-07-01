---
name: error-handling-philosophy
description: >-
  Guidelines for handling HTTP 500 Internal Server Errors and the
  relationship between engine bugs and client test behavior. Use when
  encountering 500 errors in integration tests, investigating error
  mappings, writing or reviewing error-related test assertions, or
  deciding whether to fix client-side or engine-side code.
---

# Error Handling Philosophy

## The 500 Rule

**A 500 Internal Server Error is always an engine bug.** No exceptions.

- 500 means something went genuinely wrong on the server — an uncaught
  exception, a missing error handler, or a logic gap.
- A 500 must **never** be the expected or acceptable response for any
  user-triggerable operation. Every foreseeable user action must map to
  a specific domain error with an appropriate 4xx status code.
- If an integration test observes a 500 where a 4xx was expected, **do
  not adjust the test assertion to accept 500**. Investigate the engine
  and fix the root cause.

## Do Not Paper Over Engine Bugs in the Client

When something is broken client-side (test or implementation) **because
of an actual engine bug**:

1. **Do not** adjust client behavior to accommodate the bug.
2. **Do not** weaken test assertions (e.g. `expect([409, 500])`) to
   make failing tests pass.
3. **Do** investigate the engine-side root cause.
4. **Do** fix the engine bug so it returns the correct status code and
   error body.
5. **Then** write the client test to assert the correct, intended
   behavior.

## Status Code Semantics

| Code | Meaning | When to use |
|------|---------|-------------|
| 400 | Bad Request | Malformed request body, missing required fields |
| 401 | Unauthorized | Missing or invalid authentication token |
| 403 | Forbidden | Valid token but insufficient claims/permissions |
| 404 | Not Found | Resource does not exist |
| 409 | Conflict | Version already exists, active instances block operation |
| 413 | Payload Too Large | Request body exceeds size limits |
| 422 | Unprocessable Entity | Valid request but domain rule violation (disabled process, terminal PI, FNI not waiting, contract violation) |
| 429 | Too Many Requests | Rate limit exceeded |
| 500 | Internal Server Error | **Bug. Fix it.** |

## Common 500 Root Causes

These patterns in the engine code tend to produce accidental 500s:

### Bang functions and strict pattern matching inside transactions

```elixir
# BAD — raises MatchError on failure, surfacing as 500
{:ok, record} = Ash.create(changeset, authorize?: false)

# GOOD — handle the error explicitly
case Ash.create(changeset, authorize?: false) do
  {:ok, record} -> {:ok, record}
  {:error, %Ash.Error.Invalid{} = error} -> {:error, classify(error)}
  {:error, reason} -> {:error, reason}
end
```

### Database constraint names not matching Ash identity names

Ash generates constraint names from identity names. A manually created
index with a different name will prevent Ash from intercepting the
violation, causing an uncaught `Ecto.ConstraintError` → 500.

```elixir
# Ash identity generates: {table}_{identity_name}_index
identity :unique_process_version, [:process_id, :version]
# Expected DB index: process_versions_unique_process_version_index

# If the migration uses a different name, Ash can't match it:
create unique_index(:process_versions, [:process_id, :version],
         name: "process_versions_process_version_unique_idx")  # WRONG NAME
```

### Soft-delete gaps

When a resource uses soft-delete (`deleted` flag) but:
- The unique index is **non-partial** (covers all rows including deleted)
- The pre-check read action filters `deleted == false`
- Result: pre-check says "no conflict", INSERT hits the index → 500

Fix: use a partial unique index (`WHERE deleted = false`) aligned with
the read action's filter.

### Silent error swallowing

```elixir
# BAD — converts read failures to empty set, hiding the problem
case Ash.read(query) do
  {:ok, results} -> Map.new(results, &key/1)
  _ -> %{}  # Silently swallows errors
end

# GOOD — propagate errors so callers can handle them
case Ash.read(query) do
  {:ok, results} -> {:ok, Map.new(results, &key/1)}
  {:error, reason} -> {:error, reason}
end
```

## Investigation Checklist

When you encounter a 500 in an integration test:

1. Reproduce with a direct HTTP call to see the raw error body
2. Trace the request path: Router → Controller → API facade → Core/Persistence
3. Find where the error is generated (uncaught exception? generic `{:error, reason}` fallthrough?)
4. Determine the intended domain error and status code
5. Fix the engine code to return that error
6. Update the client error mapper if needed (new error code)
7. Write/fix the client test to assert the correct behavior
