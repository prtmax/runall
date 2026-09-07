# runall

`runall` is the controlled action executor for Cosmos binary builds. The
workflow accepts only an immutable `build_spec_id`; all repository, commit,
release and artifact settings are fetched from Mercury using the service
credential configured on the runner.

## Contract

Dispatch `.github/workflows/android-build.yml` with:

```json
{
  "ref": "main",
  "inputs": { "build_spec_id": "..." }
}
```

The workflow calls `COSMOS_BUILD_SPEC_URL/<build_spec_id>` and validates the
returned `spec_hash` before checking out the requested commit. It reports a
terminal event to `COSMOS_BUILD_CALLBACK_URL/<build_id>/events`. The callback
body contains the build spec id, action run id, status and artifact manifest.

The following repository secrets are required by the workflow and are never
accepted as workflow inputs:

- `COSMOS_BUILD_SPEC_URL`
- `COSMOS_BUILD_CALLBACK_URL`
- `COSMOS_SERVICE_TOKEN`
- `COSMOS_BUILD_REPOSITORY_TOKEN` (only when the target repository is private)
