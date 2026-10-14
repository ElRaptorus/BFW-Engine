# Changelog

## Unreleased

- A 422 response with an error code the client does not know throws `ValidationError` with `errorCode` set to that code (for example `feature_not_supported`) instead of `validation_error`.

## 0.2.0

- Requires `@elraptorus/bfw_engine_sdk` 0.2.0.
- A deploy answered with 422 `validation_failed` throws `DeployValidationFailedError` with `failures` filled from the response body.

## 0.1.1

- Released alongside `@elraptorus/bfw_engine_sdk` 0.1.1.

## 0.1.0

- Initial release.
