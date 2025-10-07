# shellcheck shell=bash
#
# SSH authentication management core. Handles idempotent editing of sshd_config,
# backups, validation, and service reloads. The logic is intentionally defensive
# to lower the risk of administrators locking themselves out.

auth_init() {
    AUTH_STATE_DIR=${AUTH_STATE_DIR:-/etc/authswitch}
    AUTH_BACKUP_DIR=${AUTH_BACKUP_DIR:-${AUTH_STATE_DIR}/backups}
    AUTH_LOG_FILE=${AUTH_LOG_FILE:-/var/log/authswitch/authswitch.log}
    AUTH_SSHD_BINARY=${AUTH_SSHD_BINARY:-$(command -v sshd || true)}
    AUTH_SERVICE_MANAGER=""
    AUTH_DRY_RUN=${AUTH_DRY_RUN:-0}
    AUTH_ASSUME_YES=${AUTH_ASSUME_YES:-0}
    AUTH_NO_COLOR=${AUTH_NO_COLOR:-0}
    AUTH_VERSION=${AUTH_VERSION:-"1.0.0"}

    if [[ -n ${TEST_SSHD_CONFIG:-} ]]; then
        AUTH_SSHD_CONFIG=${TEST_SSHD_CONFIG}
        AUTH_LOG_FILE=${AUTH_LOG_FILE:-/tmp/authswitch-test.log}
        AUTH_STATE_DIR=${AUTH_STATE_DIR:-/tmp/authswitch-test}
        AUTH_BACKUP_DIR=${AUTH_STATE_DIR}/backups
        AUTH_SSHD_BINARY=true
    else
        AUTH_SSHD_CONFIG=${AUTH_SSHD_CONFIG:-/etc/ssh/sshd_config}
    fi
}

auth_require_root() {
    if [[ -n ${TEST_SSHD_CONFIG:-} ]]; then
        return
    fi
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        ui_error "This operation requires root privileges."
        exit 1
    fi
}

auth_require_sshd() {
    if [[ -z ${AUTH_SSHD_BINARY} ]]; then
        if [[ -n ${TEST_SSHD_CONFIG:-} ]]; then
            AUTH_SSHD_BINARY=true
            return
        fi
        ui_error "Unable to locate sshd binary in PATH. Install OpenSSH server first."
        exit 1
    fi
}

auth_detect_service_manager() {
    if command -v systemctl >/dev/null 2>&1; then
        AUTH_SERVICE_MANAGER="systemctl"
    elif command -v service >/dev/null 2>&1; then
        AUTH_SERVICE_MANAGER="service"
    elif [[ -x /etc/init.d/ssh ]]; then
        AUTH_SERVICE_MANAGER="/etc/init.d/ssh"
    elif [[ -x /etc/init.d/sshd ]]; then
        AUTH_SERVICE_MANAGER="/etc/init.d/sshd"
    else
        AUTH_SERVICE_MANAGER=""
    fi
}

auth_service_reload() {
    local action="$1"
    if [[ -n ${TEST_SSHD_CONFIG:-} ]]; then
        ui_info "Skipping service ${action} in test mode."
        return
    fi
    if [[ ${AUTH_DRY_RUN} -eq 1 ]]; then
        ui_info "[dry-run] Would ${action} sshd service."
        return
    fi
    case "${AUTH_SERVICE_MANAGER}" in
        systemctl)
            systemctl reload sshd 2>/dev/null || systemctl restart sshd
            ;;
        service)
            service ssh reload 2>/dev/null || service ssh restart 2>/dev/null || service sshd reload 2>/dev/null || service sshd restart
            ;;
        /etc/init.d/ssh|/etc/init.d/sshd)
            "${AUTH_SERVICE_MANAGER}" reload 2>/dev/null || "${AUTH_SERVICE_MANAGER}" restart
            ;;
        *)
            ui_warn "Unknown service manager. Please reload sshd manually."
            ;;
    esac
}

auth_log() {
    local message="$1"
    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    local actor="${SUDO_USER:-${USER:-unknown}}"
    local log_dir
    log_dir=$(dirname "${AUTH_LOG_FILE}")
    mkdir -p "${log_dir}"
    if [[ -f "${AUTH_LOG_FILE}" ]]; then
        local size
        size=$(wc -c < "${AUTH_LOG_FILE}")
        if (( size > 524288 )); then
            mv "${AUTH_LOG_FILE}" "${AUTH_LOG_FILE}.$(date -u '+%Y%m%d%H%M%S')"
        fi
    fi
    printf '%s [%s] %s\n' "${timestamp}" "${actor}" "${message}" >> "${AUTH_LOG_FILE}"
}

auth_sudo_user() {
    printf '%s\n' "${SUDO_USER:-${USER:-root}}"
}

auth_backup_config() {
    local config="${AUTH_SSHD_CONFIG}"
    local timestamp
    timestamp=$(date -u '+%Y%m%d%H%M%S')
    mkdir -p "${AUTH_BACKUP_DIR}"
    local backup
    backup=$(mktemp "${AUTH_BACKUP_DIR}/sshd_config.${timestamp}.XXXXXX")
    cp -p "${config}" "${backup}"
    auth_log "Backup created at ${backup}"
    printf '%s\n' "${backup}"
}

auth_list_backups() {
    if [[ -d "${AUTH_BACKUP_DIR}" ]]; then
        find "${AUTH_BACKUP_DIR}" -maxdepth 1 -type f -name 'sshd_config.*' -print | sort
    fi
}

auth_rollback() {
    local backup="$1"
    if [[ ! -f "${backup}" ]]; then
        ui_error "Backup ${backup} does not exist."
        exit 1
    fi
    if [[ ${AUTH_DRY_RUN} -eq 1 ]]; then
        ui_info "[dry-run] Would restore ${AUTH_SSHD_CONFIG} from ${backup}"
        return
    fi
    local current_backup
    current_backup=$(auth_backup_config)
    cp -p "${backup}" "${AUTH_SSHD_CONFIG}"
    auth_log "Rollback restored ${AUTH_SSHD_CONFIG} from ${backup}; previous config saved to ${current_backup}"
    auth_validate_config
    auth_service_reload "reload"
    ui_success "Rollback complete. Original state saved to ${current_backup}"
}

auth_validate_config() {
    if [[ -z ${AUTH_SSHD_BINARY} ]]; then
        ui_warn "sshd binary missing, skipping syntax validation."
        return 0
    fi
    if [[ "${AUTH_SSHD_BINARY}" == "true" ]]; then
        ui_info "Skipping sshd syntax validation in test mode."
        return 0
    fi
    if [[ ${AUTH_DRY_RUN} -eq 1 ]]; then
        ui_info "[dry-run] Would validate config with sshd -t."
        return 0
    fi
    if ! "${AUTH_SSHD_BINARY}" -t -f "${AUTH_SSHD_CONFIG}" >/dev/null 2>&1; then
        ui_error "sshd failed validation. Check ${AUTH_SSHD_CONFIG} before reloading."
        exit 1
    fi
}

auth_tmpfile() {
    mktemp "/tmp/authswitch.XXXXXX"
}

auth_update_global_option() {
    local option="$1"
    local value="$2"
    local tmp
    tmp=$(auth_tmpfile)
    local inserted=0
    local line trimmed
    while IFS= read -r line || [[ -n "${line}" ]]; do
        trimmed="${line#"${line%%[![:space:]]*}"}"
        if [[ "${trimmed}" =~ ^Match[[:space:]].* ]]; then
            if (( inserted == 0 )); then
                printf '%s %s\n' "${option}" "${value}" >> "${tmp}"
                inserted=1
            fi
            printf '%s\n' "${line}" >> "${tmp}"
            continue
        fi
        if [[ "${trimmed}" =~ ^#?[[:space:]]*${option}([[:space:]].*)?$ ]] && (( inserted == 0 )); then
            printf '%s %s\n' "${option}" "${value}" >> "${tmp}"
            inserted=1
            continue
        fi
        printf '%s\n' "${line}" >> "${tmp}"
    done < "${AUTH_SSHD_CONFIG}"
    if (( inserted == 0 )); then
        printf '%s %s\n' "${option}" "${value}" >> "${tmp}"
    fi
    printf '%s\n' "${tmp}"
}

auth_allow_user_block() {
    local username="$1"
    printf 'Match User %s\n    PasswordAuthentication yes\n' "${username}"
}

auth_remove_user_block() {
    local username="$1"
    local tmp
    tmp=$(auth_tmpfile)
    awk -v user="${username}" '
        BEGIN { in_block=0 }
        {
            trimmed=$0
            sub(/^[[:space:]]+/, "", trimmed)
            if (in_block == 1) {
                if (trimmed ~ /^Match[[:space:]]+/) {
                    in_block=0
                    print $0
                }
                next
            }
            if (trimmed ~ /^Match[[:space:]]+User[[:space:]]+/) {
                split(trimmed, parts, /[[:space:]]+/)
                if (parts[3] == user) {
                    in_block=1
                    next
                }
            }
            print $0
        }
    ' "${AUTH_SSHD_CONFIG}" > "${tmp}"
    printf '%s\n' "${tmp}"
}

auth_add_user_block() {
    local username="$1"
    local base tmp
    base=$(auth_remove_user_block "${username}")
    tmp=$(auth_tmpfile)
    cat "${base}" > "${tmp}"
    rm -f "${base}"
    printf '\n%s\n' "$(auth_allow_user_block "${username}")" >> "${tmp}"
    printf '%s\n' "${tmp}"
}

auth_commit_tmpfile() {
    local tmp="$1"
    local backup="$2"
    if [[ ${AUTH_DRY_RUN} -eq 1 ]]; then
        ui_info "[dry-run] Planned change preview:"
        diff -u "${AUTH_SSHD_CONFIG}" "${tmp}" || true
        rm -f "${tmp}"
        return
    fi
    if [[ -n "${backup}" ]]; then
        cp -p "${tmp}" "${AUTH_SSHD_CONFIG}"
        rm -f "${tmp}"
        auth_validate_config
        auth_service_reload "reload"
    else
        ui_error "Missing backup reference; aborting commit."
        rm -f "${tmp}"
        exit 1
    fi
}

auth_current_option() {
    local option="$1"
    awk '
        /^[[:space:]]*#/ {next}
        /^[[:space:]]*Match[[:space:]]/ {exit}
        $1 == "'"${option}"'" {print $2; exit}
    ' "${AUTH_SSHD_CONFIG}"
}

auth_current_allow_users() {
    awk '
        /^[[:space:]]*Match[[:space:]]+User[[:space:]]+/ {
            in_block=1
            allow=0
            user=$0
            sub(/^[[:space:]]*Match[[:space:]]+User[[:space:]]+/, "", user)
            sub(/[[:space:]]+.*/, "", user)
            next
        }
        {
            if (in_block == 1) {
                if ($1 == "PasswordAuthentication" && $2 == "yes") {
                    allow=1
                }
                if ($1 == "Match") {
                    if (allow == 1) {
                        print user
                    }
                    in_block=0
                }
            }
        }
        END {
            if (in_block == 1 && allow == 1) {
                print user
            }
        }
    ' "${AUTH_SSHD_CONFIG}" | sort -u
}

auth_status() {
    local passwd
    passwd=$(auth_current_option "PasswordAuthentication")
    local rootlogin
    rootlogin=$(auth_current_option "PermitRootLogin")
    local allow_users
    allow_users=$(auth_current_allow_users || true)
    printf 'PasswordAuthentication: %s\n' "${passwd:-unset}"
    printf 'PermitRootLogin: %s\n' "${rootlogin:-unset}"
    if [[ -n "${allow_users}" ]]; then
        printf 'Per-user password allow list:\n'
        printf '  %s\n' "${allow_users}"
    else
        printf 'Per-user password allow list: (none)\n'
    fi
}

auth_modify_option() {
    local option="$1"
    local value="$2"
    local tmp backup
    tmp=$(auth_update_global_option "${option}" "${value}")
    if diff -q "${AUTH_SSHD_CONFIG}" "${tmp}" >/dev/null 2>&1; then
        ui_info "No changes required; ${option} already ${value}."
        rm -f "${tmp}"
        return
    fi
    backup=""
    if [[ ${AUTH_DRY_RUN} -eq 0 ]]; then
        backup=$(auth_backup_config)
        auth_log "${option} set to ${value} via authswitch; backup ${backup}"
    else
        ui_info "[dry-run] Would set ${option} to ${value}."
    fi
    auth_commit_tmpfile "${tmp}" "${backup}"
    if [[ ${AUTH_DRY_RUN} -eq 1 ]]; then
        ui_info "Dry-run complete; ${option} remains unchanged."
    else
        ui_success "${option} updated to ${value}."
    fi
}

auth_allow_user() {
    local username="$1"
    local tmp backup
    tmp=$(auth_add_user_block "${username}")
    if diff -q "${AUTH_SSHD_CONFIG}" "${tmp}" >/dev/null 2>&1; then
        ui_info "Per-user allowance already present for ${username}."
        rm -f "${tmp}"
        return
    fi
    backup=""
    if [[ ${AUTH_DRY_RUN} -eq 0 ]]; then
        backup=$(auth_backup_config)
        auth_log "Allow password for ${username}; backup ${backup}"
    else
        ui_info "[dry-run] Would allow password for ${username}."
    fi
    auth_commit_tmpfile "${tmp}" "${backup}"
    if [[ ${AUTH_DRY_RUN} -eq 1 ]]; then
        ui_info "Dry-run complete; no per-user changes applied."
    else
        ui_success "User ${username} may authenticate with password."
    fi
}

auth_revoke_user() {
    local username="$1"
    local tmp backup
    tmp=$(auth_remove_user_block "${username}")
    if diff -q "${AUTH_SSHD_CONFIG}" "${tmp}" >/dev/null 2>&1; then
        ui_info "No per-user allowance found for ${username}."
        rm -f "${tmp}"
        return
    fi
    backup=""
    if [[ ${AUTH_DRY_RUN} -eq 0 ]]; then
        backup=$(auth_backup_config)
        auth_log "Revoke password for ${username}; backup ${backup}"
    else
        ui_info "[dry-run] Would revoke password for ${username}."
    fi
    auth_commit_tmpfile "${tmp}" "${backup}"
    if [[ ${AUTH_DRY_RUN} -eq 1 ]]; then
        ui_info "Dry-run complete; per-user settings unchanged."
    else
        ui_success "Removed per-user password access for ${username}."
    fi
}
