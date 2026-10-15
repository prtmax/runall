# runall

`runall` is the controlled GitHub Actions executor for Cosmos release app package builds.
Mercury dispatches this repository with a single platform **build run id**; repository
commits, frozen build specs, signing material, and upload credentials are resolved on the
server and exposed to jobs only through short-lived Cosmos build credentials (OIDC exchange).

## Dispatch contract (phase B wiring)

Trigger `.github/workflows/android-build.yml` with:

```json
{
  "ref": "<pinned runall revision>",
  "inputs": { "build_run_id": "<mercury-build-run-id>" }
}
```

The workflow runs four Android stages as separate jobs:

| Job | Purpose | Sensitive access |
|-----|---------|------------------|
| `prepare` | OIDC exchange, load frozen spec, validate shape/hash binding | Read spec + resources |
| `build-android` | Checkout Orion at pinned SHAs, Flutter release build (unsigned) | Read-only source clone |
| `sign-android` | zipalign/apksigner with attempt-scoped signing material | Sign material only |
| `finalize-android` | Presigned upload + terminal callback | Upload + finalize scope |

iOS IPA support will follow the same pattern in a later change; phase A focuses on
Android scripts and workflow structure.

## Scripts

| Script | Role |
|--------|------|
| `scripts/exchange-build-credential` | GitHub OIDC → Cosmos bearer token |
| `scripts/load-build-spec` | Fetch or load local frozen spec + validation |
| `scripts/build-android` | Unsigned Flutter APK/AAB from spec |
| `scripts/sign-android` | Sign APK, verify package + cert fingerprint |
| `scripts/upload-artifacts` | Request presigned PUT and upload |
| `scripts/report-result` | Attempt progress / terminal status callback |

Local contract tests (no network):

```bash
./scripts/tests/run-contract-tests.sh
```

## Repository secrets (runner configuration)

Never pass these as workflow dispatch inputs:

- `COSMOS_BUILD_AUTH_EXCHANGE_URL` — `POST /internal/build-auth/exchange`
- `COSMOS_BUILD_SPEC_URL` — immutable spec documents per run
- `COSMOS_BUILD_CALLBACK_URL` — attempt event callback base
- `COSMOS_BUILD_ARTIFACT_UPLOAD_URL` — finalize upload API base
- `COSMOS_BUILD_SIGN_MATERIAL_URL` — attempt-scoped Android signing API base
- `COSMOS_BUILD_REPOSITORY_TOKEN` — optional private clone token

Legacy `COSMOS_SERVICE_TOKEN` / `build_spec_id` dispatch is replaced by `build_run_id`
and OIDC; keep old secrets only until Mercury cutover completes.

## Phase A scope (COSMOS-62)

This repository change delivers executor scripts, split Android workflow jobs, contract
tests, and documentation. Cosmos Mercury dispatcher, OIDC API, and Release UI integration
are implemented in phase B after COSMOS-59 handoff.
