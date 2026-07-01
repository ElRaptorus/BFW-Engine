---
name: maintain-documentation
description: >-
  Step-by-step instructions for keeping architecture and project documentation
  in sync with code changes. Use after modifying code, adding modules, changing
  endpoints, updating schemas, or altering the project structure. Ensures
  documentation never falls out of date.
---

# Maintaining Documentation

After any code change, follow these steps to keep documentation in sync. For the full code-change-to-documentation mapping table and detailed update patterns, see `reference.md` in this skill folder.

## Step 1: Identify Affected Documentation

Use the mapping table in `reference.md` to determine which docs need updating based on what you changed.

## Step 2: Update the Affected Files

For each affected file:

1. Read the current content
2. Find the relevant section
3. Update it to reflect the code change
4. Ensure cross-references remain valid

## Step 3: Verify Cross-References

After updating, check that:

- `docs/architecture/index.md` lists all topic files (no missing entries)
- Links between architecture docs are not broken
- `docs/ImplementationPhases.md` references point to correct architecture doc paths
- `docs/Glossary.md` "See also" table entries point to correct paths
- `docs/Architecture.md` mapping table references correct architecture docs

## Step 4: Confirm Completeness

Ask yourself:
- Would a new developer reading these docs get an accurate picture of the current engine?
- Are there any sections that now describe code that no longer exists?
- Are all new modules, behaviours, endpoints, or patterns documented?

## Exclusions

The following docs are NOT updated automatically — only when the user explicitly requests it:
- `docs/Concept.md` — Original product concept (historical document)
