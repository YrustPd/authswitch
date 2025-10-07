# shellcheck shell=bash
#
# UI helpers for authswitch. These routines keep presentation logic isolated
# from operational code so we can support both interactive and automated use.

set -euo pipefail

AUTH_UI_COLOR_ENABLE=1

ui_init() {
    local no_color=${AUTH_NO_COLOR:-0}
    if [[ ${no_color} -eq 1 ]]; then
        AUTH_UI_COLOR_ENABLE=0
        return
    fi

    if [[ ! -t 1 ]]; then
        AUTH_UI_COLOR_ENABLE=0
        return
    fi

    if ! command -v tput >/dev/null 2>&1; then
        AUTH_UI_COLOR_ENABLE=0
        return
    fi

    if [[ $(tput colors 2>/dev/null || echo 0) -lt 8 ]]; then
        AUTH_UI_COLOR_ENABLE=0
    fi
}

ui_color() {
    local code="$1"
    if [[ ${AUTH_UI_COLOR_ENABLE} -eq 1 ]]; then
        printf '\033[%sm' "${code}"
    fi
}

ui_reset() {
    if [[ ${AUTH_UI_COLOR_ENABLE} -eq 1 ]]; then
        printf '\033[0m'
    fi
}

ui_info() {
    ui_print "36" "$@"
}

ui_warn() {
    ui_print "33" "$@"
}

ui_error() {
    ui_print "31" "$@"
}

ui_success() {
    ui_print "32" "$@"
}

ui_print() {
    local color="$1"
    shift
    if [[ -n "${*:-}" ]]; then
        ui_color "${color}"
        printf '%s' "$*"
        ui_reset
        printf '\n'
    fi
}

ui_heading() {
    local text="$1"
    printf '\n'
    ui_color "1;34"
    printf '%s' "${text}"
    ui_reset
    printf '\n'
    printf '%*s\n' "${#text}" '' | tr ' ' '-'
}

ui_prompt_confirm() {
    local prompt="$1"
    local default="${2:-}"
    local reply
    while true; do
        if [[ "${default}" == "y" ]]; then
            printf '%s [Y/n]: ' "${prompt}"
        elif [[ "${default}" == "n" ]]; then
            printf '%s [y/N]: ' "${prompt}"
        else
            printf '%s [y/n]: ' "${prompt}"
        fi
        if ! read -r reply; then
            return 1
        fi
        reply=${reply:-${default}}
        case "${reply}" in
            y|Y) return 0 ;;
            n|N) return 1 ;;
            *) ui_warn "Please answer y or n." ;;
        esac
    done
}

ui_prompt_select() {
    local prompt="$1"
    shift
    local options=("$@")
    local idx
    ui_info "${prompt}"
    for idx in "${!options[@]}"; do
        printf '  [%d] %s\n' "$((idx + 1))" "${options[$idx]}"
    done
    printf 'Select an option: '
    local choice
    if ! read -r choice; then
        return 1
    fi
    if [[ "${choice}" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#options[@]})); then
        printf '%s\n' "${options[$((choice - 1))]}"
        return 0
    fi
    ui_warn "Invalid selection."
    return 1
}

ui_menu_loop() {
    local title="$1"
    local selections_var="$2"
    local handlers_var="$3"
    local quit_label="${4:-Quit}"

    local -n menu_selections="${selections_var}"
    local -n menu_handlers="${handlers_var}"

    while true; do
        ui_heading "${title}"
        local idx
        for idx in "${!menu_selections[@]}"; do
            printf '  [%d] %s\n' "$((idx + 1))" "${menu_selections[$idx]}"
        done
        printf '  [q] %s\n' "${quit_label}"
        printf 'Select an option: '
        local input
        if ! read -r input; then
            printf '\n'
            break
        fi
        case "${input}" in
            q|Q) break ;;
            *)
                if [[ "${input}" =~ ^[0-9]+$ ]] && ((input >= 1 && input <= ${#menu_selections[@]})); then
                    local handler="${menu_handlers[$((input - 1))]}"
                    if [[ -n "${handler}" ]]; then
                        "${handler}"
                    fi
                else
                    ui_warn "Invalid option."
                fi
                ;;
        esac
    done
}

ui_version() {
    printf '%s\n' "${AUTH_VERSION:-unknown}"
}

ui_usage() {
    cat <<'EOF'
Usage: authswitch [options] <subcommand> [args]

Subcommands:
  status                          Show current SSH authentication settings
  enable-password-login           Set PasswordAuthentication yes
  disable-password-login          Set PasswordAuthentication no
  enable-root-password            Set PermitRootLogin yes
  disable-root-password           Set PermitRootLogin no
  allow-password-for-user <user>  Allow password login for a specific user
  revoke-password-for-user <user> Remove per-user password allowance
  list-backups                    List existing backups
  rollback <backup-file>          Restore sshd_config from backup
  interactive                     Launch interactive menu

Options:
  --dry-run       Show planned actions without applying them
  --yes           Assume yes for confirmations
  --no-color      Disable colored output
  --log <path>    Override log file location
  --version       Show version
  --help          Show this help text
EOF
}

ui_init
