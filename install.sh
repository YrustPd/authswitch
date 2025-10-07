#!/usr/bin/env bash
set -euo pipefail

umask 022

REPO_OWNER="YrustPd"
REPO_NAME="authswitch"
REPO_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}"
AUTH_REF="${AUTH_REF:-main}"

SUDO_CMD=""

require_cmd() {
    local cmd="$1"
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        echo "Required command '${cmd}' not found in PATH." >&2
        exit 1
    fi
}

ensure_privileges() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        if command -v sudo >/dev/null 2>&1; then
            SUDO_CMD="sudo"
            echo "Elevating privileges with sudo..."
        else
            echo "authswitch installer requires root privileges. Install sudo or rerun as root." >&2
            exit 1
        fi
    fi
}

run_root() {
    if [[ -n "${SUDO_CMD}" ]]; then
        ${SUDO_CMD} "$@"
    else
        "$@"
    fi
}

PKG_MANAGER=""

detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
    else
        PKG_MANAGER=""
    fi
}

update_system_packages() {
    local rc
    case "${PKG_MANAGER}" in
        apt)
            echo "Updating apt package lists..."
            set +e
            run_root env DEBIAN_FRONTEND=noninteractive apt-get update -y
            rc=$?
            set -e
            if [[ ${rc} -ne 0 ]]; then
                echo "Warning: apt-get update encountered errors; continuing with existing package metadata."
            fi
            echo "Upgrading apt packages..."
            set +e
            run_root env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
            rc=$?
            set -e
            if [[ ${rc} -ne 0 ]]; then
                echo "Warning: apt-get upgrade encountered errors; continuing without full upgrade."
            fi
            ;;
        dnf)
            echo "Refreshing dnf metadata..."
            set +e
            run_root dnf makecache
            rc=$?
            set -e
            if [[ ${rc} -ne 0 ]]; then
                echo "Warning: dnf makecache encountered errors; continuing."
            fi
            echo "Upgrading dnf packages..."
            set +e
            run_root dnf upgrade -y
            rc=$?
            set -e
            if [[ ${rc} -ne 0 ]]; then
                echo "Warning: dnf upgrade encountered errors; continuing."
            fi
            ;;
        yum)
            echo "Refreshing yum metadata..."
            set +e
            run_root yum makecache
            rc=$?
            set -e
            if [[ ${rc} -ne 0 ]]; then
                echo "Warning: yum makecache encountered errors; continuing."
            fi
            echo "Upgrading yum packages..."
            set +e
            run_root yum update -y
            rc=$?
            set -e
            if [[ ${rc} -ne 0 ]]; then
                echo "Warning: yum update encountered errors; continuing."
            fi
            ;;
        *)
            echo "Package manager not detected; skipping automated updates.";
            ;;
    esac
}

install_dependencies() {
    local deps=(curl tar grep sed openssh-server)
    local rc
    case "${PKG_MANAGER}" in
        apt)
            echo "Installing dependencies via apt (${deps[*]})..."
            set +e
            run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "${deps[@]}"
            rc=$?
            set -e
            if [[ ${rc} -ne 0 ]]; then
                echo "Warning: apt-get install encountered errors; continuing."
            fi
            ;;
        dnf)
            echo "Installing dependencies via dnf (${deps[*]})..."
            set +e
            run_root dnf install -y "${deps[@]}"
            rc=$?
            set -e
            if [[ ${rc} -ne 0 ]]; then
                echo "Warning: dnf install encountered errors; continuing."
            fi
            ;;
        yum)
            echo "Installing dependencies via yum (${deps[*]})..."
            set +e
            run_root yum install -y "${deps[@]}"
            rc=$?
            set -e
            if [[ ${rc} -ne 0 ]]; then
                echo "Warning: yum install encountered errors; continuing."
            fi
            ;;
        *)
            echo "Skipping dependency installation; unsupported package manager.";
            ;;
    esac
}

ensure_awk() {
    if command -v awk >/dev/null 2>&1; then
        return
    fi
    case "${PKG_MANAGER}" in
        apt)
            echo "Installing gawk because awk was not detected..."
            set +e
            run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y gawk mawk
            local rc=$?
            set -e
            if [[ ${rc} -ne 0 ]]; then
                echo "Warning: Unable to install awk implementation automatically. Continue with caution."
            elif ! command -v awk >/dev/null 2>&1; then
                echo "Warning: awk still not detected after installation attempt. Continue with caution."
            fi
            ;;
        dnf)
            echo "Installing gawk because awk was not detected..."
            set +e
            run_root dnf install -y gawk
            local rc=$?
            set -e
            if [[ ${rc} -ne 0 ]]; then
                echo "Warning: Unable to install gawk automatically. Continue with caution."
            elif ! command -v awk >/dev/null 2>&1; then
                echo "Warning: awk still not detected after installation attempt. Continue with caution."
            fi
            ;;
        yum)
            echo "Installing gawk because awk was not detected..."
            set +e
            run_root yum install -y gawk
            local rc=$?
            set -e
            if [[ ${rc} -ne 0 ]]; then
                echo "Warning: Unable to install gawk automatically. Continue with caution."
            elif ! command -v awk >/dev/null 2>&1; then
                echo "Warning: awk still not detected after installation attempt. Continue with caution."
            fi
            ;;
        *)
            echo "Warning: awk not found and package manager unsupported for automatic installation."
            ;;
    esac
}

ARCHIVE_TMP=""

cleanup() {
    if [[ -n "${ARCHIVE_TMP}" && -d "${ARCHIVE_TMP}" ]]; then
        rm -rf "${ARCHIVE_TMP}"
    fi
}

trap cleanup EXIT

SCRIPT_PATH=""
if [[ -n ${BASH_SOURCE+x} ]]; then
    SCRIPT_PATH="${BASH_SOURCE[0]}"
fi

if [[ -n "${SCRIPT_PATH}" && "${SCRIPT_PATH}" != "-" ]]; then
    SCRIPT_DIR=$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)
else
    SCRIPT_DIR=""
fi

ensure_privileges
detect_pkg_manager
update_system_packages
install_dependencies
ensure_awk

ensure_sshd() {
    if run_root bash -lc 'command -v sshd >/dev/null 2>&1'; then
        return
    fi
    echo "Warning: sshd binary not detected after dependency installation."
    case "${PKG_MANAGER}" in
        apt)
            set +e
            run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server
            local rc=$?
            set -e
            if [[ ${rc} -ne 0 ]]; then
                echo "Warning: Unable to install openssh-server automatically."
            fi
            ;;
        dnf)
            set +e
            run_root dnf install -y openssh-server
            local rc=$?
            set -e
            if [[ ${rc} -ne 0 ]]; then
                echo "Warning: Unable to install openssh-server automatically."
            fi
            ;;
        yum)
            set +e
            run_root yum install -y openssh-server
            local rc=$?
            set -e
            if [[ ${rc} -ne 0 ]]; then
                echo "Warning: Unable to install openssh-server automatically."
            fi
            ;;
    esac
    if ! run_root bash -lc 'command -v sshd >/dev/null 2>&1'; then
        echo "OpenSSH server (sshd) could not be detected; aborting."
        exit 1
    fi
}

ensure_sshd

ensure_sshd

if [[ -n "${SCRIPT_DIR}" && -f "${SCRIPT_DIR}/bin/authswitch" ]]; then
    REPO_ROOT=$(cd "${SCRIPT_DIR}" && pwd)
else
    require_cmd curl
    require_cmd tar
    ARCHIVE_TMP=$(mktemp -d /tmp/authswitch-install.XXXXXX)
    ARCHIVE_PATH="${ARCHIVE_TMP}/${REPO_NAME}.tar.gz"
    echo "Fetching ${REPO_URL} (${AUTH_REF})..."
    download_archive() {
        local url
        for url in \
            "${REPO_URL}/archive/refs/heads/${AUTH_REF}.tar.gz" \
            "${REPO_URL}/archive/refs/tags/${AUTH_REF}.tar.gz" \
            "${REPO_URL}/archive/${AUTH_REF}.tar.gz"
        do
            if curl -fsSL "${url}" -o "${ARCHIVE_PATH}"; then
                echo "Downloaded ${url}"
                return 0
            fi
        done
        return 1
    }
    if ! download_archive; then
        echo "Failed to download archive for ref '${AUTH_REF}'." >&2
        exit 1
    fi
    tar -xzf "${ARCHIVE_PATH}" -C "${ARCHIVE_TMP}"
    REPO_ROOT=$(find "${ARCHIVE_TMP}" -mindepth 1 -maxdepth 1 -type d -print | head -n1)
    if [[ -z "${REPO_ROOT}" || ! -d "${REPO_ROOT}" ]]; then
        echo "Unable to locate extracted project directory." >&2
        exit 1
    fi
fi

BIN_SRC="${REPO_ROOT}/bin/authswitch"
LIB_SRC="${REPO_ROOT}/lib"
SHARE_SRC="${REPO_ROOT}/examples"

if [[ ! -f "${BIN_SRC}" ]]; then
    echo "authswitch binary not found in ${REPO_ROOT}. Installation aborted." >&2
    exit 1
fi

require_cmd install
require_cmd cp



if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID_LIKE:-${ID:-}}" in
        *debian*|*ubuntu*|*rhel*|*fedora*|*centos*|*rocky*|*almalinux*)
            ;;
        *)
            echo "Warning: ${NAME:-Unknown OS} is not in the tested Debian/Ubuntu or RHEL/CentOS families." >&2
            ;;
    esac
fi

BIN_DIR="/usr/local/bin"
SHARE_DIR="/usr/local/share/authswitch"
LIB_DIR="${SHARE_DIR}/lib"
EXAMPLE_DIR="${SHARE_DIR}/examples"
DOC_DIR="${SHARE_DIR}/docs"
CONFIG_DIR="/etc/authswitch"
BACKUP_DIR="${CONFIG_DIR}/backups"
LOG_DIR="/var/log/authswitch"

echo "Installing authswitch binaries and libraries..."
run_root install -d -m 0755 "${BIN_DIR}"
run_root install -d -m 0755 "${SHARE_DIR}"
run_root install -d -m 0755 "${LIB_DIR}"
run_root install -d -m 0755 "${EXAMPLE_DIR}"
run_root install -d -m 0755 "${DOC_DIR}"

run_root install -m 0755 "${BIN_SRC}" "${BIN_DIR}/authswitch"
run_root install -m 0644 "${LIB_SRC}"/*.sh "${LIB_DIR}/"

if [[ -d "${SHARE_SRC}" ]]; then
    run_root cp -a "${SHARE_SRC}/." "${EXAMPLE_DIR}/"
fi

run_root install -d -m 0750 "${CONFIG_DIR}"
run_root install -d -m 0750 "${BACKUP_DIR}"
run_root install -d -m 0750 "${LOG_DIR}"
run_root touch "${LOG_DIR}/authswitch.log"
run_root chmod 0640 "${LOG_DIR}/authswitch.log"

run_root install -m 0644 /dev/stdin "${DOC_DIR}/README.txt" <<'EOF'
authswitch installed components

- /usr/local/bin/authswitch        CLI entrypoint
- /usr/local/share/authswitch/lib  Shared bash modules
- /etc/authswitch                  Host-specific configuration and backups
- /var/log/authswitch              Audit logs

Example automation: create /etc/systemd/system/authswitch-audit.timer and .service files
based on the snippets shipped with the project if periodic compliance checks are required.
EOF

if [[ ! -f "${CONFIG_DIR}/authswitch.cron.example" ]]; then
    run_root install -m 0640 /dev/stdin "${CONFIG_DIR}/authswitch.cron.example" <<'EOF'
# Example cron snippet for nightly sshd compliance reporting.
# 0 2 * * * root /usr/local/bin/authswitch --dry-run status >> /var/log/authswitch/audit.cron.log 2>&1
EOF
fi

echo "authswitch installed successfully."
echo "Binaries: ${BIN_DIR}/authswitch"
echo "Libraries: ${LIB_DIR}"
echo "Logs: ${LOG_DIR}/authswitch.log"
