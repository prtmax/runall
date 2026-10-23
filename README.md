# runall

`runall` is the controlled GitHub Actions executor for Cosmos native Flutter app builds.
Mercury dispatches this repository with a single platform **build run id**; repository
commits, frozen build specs, signing material, and upload credentials are resolved on the
server and exposed to jobs only through short-lived Cosmos build credentials (OIDC exchange).

## Dispatch contract (phase B wiring)

The workflow run name is `cosmos-build-<build_run_id>` so Mercury can reconcile
a dispatch that did not return a GitHub run id. Trigger `.github/workflows/android-build.yml` with:

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

The build source is fixed to `prtmax/orion`. Prepare fetches the trusted `main`
ref and accepts a frozen commit only when it is an ancestor of that ref. A feature
branch, pull request ref, fork, or repository named by a build payload cannot
supply executable assembler code. Publish a catalog for production only after its
Orion commit has merged into the trusted `main` history.

| Job | Purpose | Sensitive access |
|-----|---------|------------------|
| `prepare` | OIDC exchange, load frozen spec, recompute canonical hash and resource digests, checkout source | Read spec + resources; clone token stays in this job |
| `build-android` | Flutter release APK/AAB from the prepared workspace, unsigned | None |
| `sign-android` | APK zipalign/apksigner or AAB jarsigner, version and certificate checks | Sign material only |
| `finalize-android` | Presigned upload + terminal callback, including upstream failure | Upload + finalize scope |
| `build-ios` | Unsigned `flutter build ios --release --no-codesign` | None |
| `sign-ios` | Certificate, profile, team, and bundle checks, then IPA packaging | Sign material only |
| `finalize-ios` | Presigned IPA upload + terminal callback, including upstream failure | Upload + finalize scope |

Real keystore, Apple certificate, object storage, and device install checks stay outside
this repository. Missing material or tools fail the job; they do not produce a debug package.

## Scripts

The executor accepts immutable `cosmos.native-build.v1` snapshots and
`cosmos.native-build.v2` snapshots containing an `app-appearance.v1` envelope.
The outer and input schema versions must match. Appearance is forbidden on v1;
v2 requires a unique style collection with a valid default style and default
theme for each style. The reviewed Orion assembler validates complete feature
coverage, theme snapshots and the default-style projection before generating
the package. Prepare does not fetch current appearance settings or color tokens.
All bundled styles and themes come from the frozen input and resource manifest.

| Script | Role |
|--------|------|
| `scripts/exchange-build-credential` | GitHub OIDC → Cosmos bearer token |
| `scripts/load-build-spec` | Fetch or load local frozen spec + validation |
| `scripts/checkout-source` | Prepare-only clone of a direct Orion repo or a Cosmos checkout with its Orion submodule. Token is a per-command header, never a remote URL |
| `scripts/ensure-flutter` | Install the Flutter SDK pinned by `buildInput.source.flutterVersion` and `.fvmrc` |
| `scripts/build-android` | Unsigned Flutter APK/AAB from the frozen Orion app assembler and packaging overlay |
| `scripts/sign-android` | Sign APK, verify package, version, and cert fingerprint |
| `scripts/sign-aab` | Sign AAB with jarsigner, verify version and cert fingerprint |
| `scripts/build-ios` | Unsigned iOS Runner.app from frozen Orion app assembler output, packed as a tar so symlinks survive upload |
| `scripts/sign-ios` | Sign Runner.app, package IPA, record the sign result |
| `scripts/upload-artifacts` | Authorize with `byteSize`, PUT only to the granted https URL, then call artifact complete |
| `scripts/report-result` | Attempt progress / terminal status callback |

Frozen packaging bytes are never fetched from arbitrary `ref` URLs. For `app-studio/*` refs, prepare calls `GET ${COSMOS_BUILD_SPEC_URL%/}/${build_run_id}/packaging-resources` with its stage credential, accepts only refs frozen in `buildInput.resources`, and recomputes the lowercase SHA-256 digest. Non-studio refs require an authorized local index. Compile receives only the verified resource artifact and rechecks every digest before running Orion's native app assembler. It has no OIDC, platform credential, or signing key.

App Studio language resources are frozen `application/zip` objects containing all
selected languages, labels and locale defaults. Prepare treats them as bounded,
digest-verified bytes; Orion validates the archive before generating bundled assets.
Raw FTL packaging responses are rejected.

Frozen `feature_asset` resources retain registry logical keys and exact content
references. Prepare supports PNG/SVG/WebP bytes as well as language ZIPs, accepts
at most 512 resource objects and 36 MiB total, and rejects missing, extra, repeated
or digest-mismatched refs. Orion validates selected presentation requirements and
generates the bundled registry index; development assets cannot fill missing
product requirements.

Local contract tests (no network):

```bash
./scripts/tests/run-contract-tests.sh
```

With the pinned Orion and Cosmos checkouts available, the cross-repo check also runs the real generator and compares the Mercury upload schema:

```bash
ORION_ROOT=/path/to/orion COSMOS_ROOT=/path/to/cosmos ./scripts/tests/cross-repo-contract.sh
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
