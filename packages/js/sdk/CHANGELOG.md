# Changelog

## 0.2.0

- Breaking: `linterScores` moved from `BpmnProcess` to `BpmnDefinitions`, matching the engine's parser. The entries are read from `definitions/extensionElements/bfw:properties/bfw:linterRulesetScore`.
- Breaking: `LinterRulesetScore` carries the nine attributes the engine reads (`rulesetId`, `scorePercent`, `complianceStatus`, `computedAtIso`, `schemaVersion`, `maxPoints`, `penaltyPoints`, `rawErrorFindings`, `rawWarningFindings`) instead of `score` and `checks`. Absent or unparseable values are `null`.
- Breaking: the `ruleset-id` attribute alias is no longer read.
- An empty `rulesetId` skips the entry.
- `DeployValidationFailedError.failures` lists the per-file deploy failures (`{ file, details }`) from the engine's 422 body. Breaking: the constructor is now `(message, failures?, rawBody?)`.

## 0.1.1

- `parseBpmn` rejects malformed XML with an error naming line and column, and rejects DOCTYPE declarations, matching the engine's parser.
- `parseBpmn` reads multi-instance `inputDataItem` / `outputDataItem` variable names from the `name` attribute, as the engine does.

## 0.1.0

- Initial release.
