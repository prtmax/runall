# runall

`runall` is the controlled action executor for Cosmos app package builds. The
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
returned `specHash` before checking out the requested commit. Build Specs select
exactly one platform:

- `platform: "android"` with `targets: ["apk"]`, `["aab"]`, or `["apk","aab"]`
- `platform: "ios"` with `targets: ["ipa"]`

Android runs on an Ubuntu runner and builds APK/AAB through Gradle. iOS runs on
a macOS runner and builds IPA through Flutter/Xcode export. Both paths report
`running`, then a terminal `succeeded` or `failed` event to
`COSMOS_BUILD_CALLBACK_URL/<build_spec_id>/events`.

The following repository secrets are required by the workflow and are never
accepted as workflow inputs:

- `COSMOS_BUILD_SPEC_URL`
- `COSMOS_BUILD_CALLBACK_URL`
- `COSMOS_SERVICE_TOKEN`
- `COSMOS_BUILD_REPOSITORY_TOKEN` (only when the target repository is private)

The iOS IPA path also requires Apple signing material in repository secrets:

- `IOS_CERTIFICATE_P12_BASE64`
- `IOS_CERTIFICATE_PASSWORD`
- `IOS_PROVISIONING_PROFILE_BASE64`
- `IOS_EXPORT_OPTIONS_PLIST_BASE64`
- `IOS_KEYCHAIN_PASSWORD`

Do not place Apple signing material, service tokens, repository tokens, or OSS
credentials in the Build Spec or workflow dispatch inputs. The dispatch input is
only `build_spec_id`; every sensitive value is resolved by GitHub Actions
Secrets on the runner.
