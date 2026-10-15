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

The dispatch workflow calls three reusable workflows for the sensitive stages
(`reusable-prepare.yml`, `reusable-sign-android.yml`, `reusable-finalize-android.yml`),
each pinned to a full commit SHA. Update that pin in the same change that edits a
sensitive workflow. The contract test rebuilds those commits from checked-in
objects, so a depth-1 pull request checkout can prove the pin without fetching
ancestors.
The compile job is an ordinary job with `contents: read` only: no `id-token: write`,
no repository token, and no signing material. Prepare checks out the frozen source
and uploads that workspace. Finalize still runs when compile or sign fails so the
platform receives a failed callback.

| Job | Purpose | Sensitive access |
|-----|---------|------------------|
| `prepare` | OIDC exchange, load frozen spec, recompute canonical hash and resource digests, checkout source | Read spec + resources; clone token stays in this job |
| `build-android` | Flutter release APK/AAB from the prepared workspace, unsigned | None |
| `sign-android` | APK zipalign/apksigner or AAB jarsigner, version and certificate checks | Sign material only |
| `finalize-android` | Presigned upload + terminal callback, including upstream failure | Upload + finalize scope |

iOS IPA support will follow the same pattern in a later change; phase A focuses on
Android scripts and workflow structure.

## Scripts

| Script | Role |
|--------|------|
| `scripts/exchange-build-credential` | GitHub OIDC → Cosmos bearer token |
| `scripts/load-build-spec` | Fetch or load local frozen spec + validation |
| `scripts/checkout-source` | Prepare-only clone. Token is a per-command header, never a remote URL |
| `scripts/build-android` | Unsigned Flutter APK/AAB from an existing checkout |
| `scripts/sign-android` | Sign APK, verify package, version, and cert fingerprint |
| `scripts/sign-aab` | Sign AAB with jarsigner, verify version and cert fingerprint |
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
