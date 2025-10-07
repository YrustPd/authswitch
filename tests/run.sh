#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)

BIN="${PROJECT_ROOT}/bin/authswitch"
FIXTURE="${SCRIPT_DIR}/fixtures/sshd_config"

if [[ ! -x "${BIN}" ]]; then
    echo "authswitch binary not found. Run tests from project root." >&2
    exit 1
fi

tmpdir=$(mktemp -d /tmp/authswitch-test.XXXXXX)
trap 'rm -rf "${tmpdir}"' EXIT

CONFIG="${tmpdir}/sshd_config"
cp "${FIXTURE}" "${CONFIG}"

export TEST_SSHD_CONFIG="${CONFIG}"
export AUTH_LOG_FILE="${tmpdir}/authswitch.log"
export AUTH_STATE_DIR="${tmpdir}/state"
mkdir -p "${AUTH_STATE_DIR}"

echo "[1/6] status (dry run environment)"
"${BIN}" status >/dev/null

echo "[2/6] disable-root-password --dry-run leaves config untouched"
sha_before=$(sha256sum "${CONFIG}" | awk '{print $1}')
"${BIN}" --dry-run --yes disable-root-password >/dev/null
sha_after=$(sha256sum "${CONFIG}" | awk '{print $1}')
if [[ "${sha_before}" != "${sha_after}" ]]; then
    echo "Dry-run modified configuration unexpectedly." >&2
    exit 1
fi

echo "[3/6] disable-root-password applies change"
"${BIN}" --yes disable-root-password >/dev/null
if ! grep -q '^PermitRootLogin no' "${CONFIG}"; then
    echo "Expected PermitRootLogin no in config." >&2
    exit 1
fi

echo "[4/6] allow-password-for-user root adds Match block"
"${BIN}" --yes allow-password-for-user root >/dev/null
if ! grep -q '^Match User root' "${CONFIG}"; then
    echo "Match block for root missing." >&2
    exit 1
fi

echo "[5/6] revoke-password-for-user root removes Match block"
"${BIN}" --yes revoke-password-for-user root >/dev/null
if grep -q '^Match User root' "${CONFIG}"; then
    echo "Match block for root still present after revoke." >&2
    exit 1
fi

echo "[6/6] backup files created"
backup_count=$(find "${AUTH_STATE_DIR}/backups" -type f -name 'sshd_config.*' 2>/dev/null | wc -l | tr -d ' ')
if [[ "${backup_count}" -lt 2 ]]; then
    echo "Expected at least two backups, found ${backup_count}." >&2
    exit 1
fi

echo "All tests passed."
