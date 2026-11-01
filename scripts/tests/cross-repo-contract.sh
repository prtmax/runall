#!/usr/bin/env bash
# Verify shared canonical vectors and the real Dart assembler across repositories.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${ORION_ROOT:?Set ORION_ROOT to the migrated Orion checkout}"
: "${COSMOS_ROOT:?Set COSMOS_ROOT to the Cosmos checkout}"
cd "$ROOT_DIR/tools/cosmos_executor"
dart test test/cross_repo_test.dart
