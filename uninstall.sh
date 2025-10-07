#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "authswitch uninstaller must run as root." >&2
    exit 1
fi

YES=0
RESTORE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y)
            YES=1
            shift
            ;;
        --restore-last)
            RESTORE=1
            shift
            ;;
        --help|-h)
            cat <<'EOF'
Usage: uninstall.sh [--yes] [--restore-last]

  --yes           Proceed without interactive confirmation
  --restore-last  Restore the most recent /etc/authswitch/backups/sshd_config.* backup
EOF
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

confirm() {
    local prompt="$1"
    if [[ ${YES} -eq 1 ]]; then
        return 0
    fi
    read -r -p "${prompt} [y/N]: " reply || return 1
    case "${reply}" in
        y|Y) return 0 ;;
        *) return 1 ;;
    esac
}

BIN_PATH="/usr/local/bin/authswitch"
SHARE_DIR="/usr/local/share/authswitch"
LIB_DIR="${SHARE_DIR}/lib"
CONFIG_DIR="/etc/authswitch"
BACKUP_DIR="${CONFIG_DIR}/backups"
LOG_DIR="/var/log/authswitch"
SSHD_CONFIG="/etc/ssh/sshd_config"

if [[ ! -x "${BIN_PATH}" ]]; then
    echo "authswitch binary not found at ${BIN_PATH}; nothing to uninstall."
fi

if ! confirm "Remove authswitch binaries and libraries?"; then
    echo "Uninstall aborted."
    exit 1
fi

rm -f "${BIN_PATH}"
rm -rf "${LIB_DIR}"
rm -rf "${SHARE_DIR}"

if [[ ${RESTORE} -eq 1 ]]; then
    if [[ -d "${BACKUP_DIR}" ]]; then
        latest=$(find "${BACKUP_DIR}" -maxdepth 1 -type f -name 'sshd_config.*' -print 2>/dev/null | sort | tail -n1 || true)
        if [[ -n "${latest}" ]]; then
            echo "Restoring ${SSHD_CONFIG} from ${latest}"
            cp -p "${latest}" "${SSHD_CONFIG}"
            if command -v sshd >/dev/null 2>&1; then
                if sshd -t -f "${SSHD_CONFIG}"; then
                    if command -v systemctl >/dev/null 2>&1; then
                        systemctl reload sshd || systemctl restart sshd
                    elif command -v service >/dev/null 2>&1; then
                        service ssh reload 2>/dev/null || service ssh restart
                    fi
                else
                    echo "Warning: sshd validation failed for restored config. Review ${SSHD_CONFIG}." >&2
                fi
            fi
        else
            echo "No backups available in ${BACKUP_DIR}."
        fi
    else
        echo "Backup directory ${BACKUP_DIR} not found; skipping restore."
    fi
fi

if [[ -d "${CONFIG_DIR}" ]]; then
    if confirm "Remove ${CONFIG_DIR}?"; then
        rm -rf "${CONFIG_DIR}"
    fi
fi

if [[ -d "${LOG_DIR}" ]]; then
    if confirm "Delete logs in ${LOG_DIR}?"; then
        rm -rf "${LOG_DIR}"
    fi
fi

echo "authswitch components removed."
