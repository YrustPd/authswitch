# shellcheck shell=bash
#
# User discovery helpers for authswitch. These utilities avoid assumptions
# about user database layouts and rely on getent so LDAP/SSSD deployments
# behave correctly.

users_min_uid() {
    local os_release="/etc/os-release"
    local min_uid=1000
    if [[ -f "${os_release}" ]] && grep -qiE '^(id_like|id)=.*rhel' "${os_release}"; then
        min_uid=500
    fi
    printf '%s\n' "${min_uid}"
}

users_list_login_accounts() {
    local min_uid
    min_uid=$(users_min_uid)
    getent passwd | awk -F: -v min_uid="${min_uid}" '
        $3 >= min_uid && $7 !~ /(false|nologin)$/ && $7 != ""
        {print $1 ":" $5 ":" $3 ":" $6 ":" $7}
    '
}

users_exists() {
    local username="$1"
    getent passwd "${username}" >/dev/null 2>&1
}

users_list_all_names() {
    users_list_login_accounts | awk -F: '{print $1}'
}

users_describe() {
    local username="$1"
    getent passwd "${username}" | awk -F: '{print $1 ":" $5 ":" $3 ":" $6 ":" $7}'
}

users_select_interactive() {
    local -a user_list=()
    while IFS= read -r line; do
        user_list+=("${line}")
    done < <(users_list_login_accounts)

    if [[ ${#user_list[@]} -eq 0 ]]; then
        return 1
    fi

    local idx=1
    for entry in "${user_list[@]}"; do
        local name _full _uid _home shell
        IFS=':' read -r name _full _uid _home shell <<<"${entry}"
        printf '  [%d] %s (%s)\n' "${idx}" "${name}" "${shell}"
        idx=$((idx + 1))
    done
    printf 'Select a user: '
    local choice
    if ! read -r choice; then
        return 1
    fi
    if [[ "${choice}" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#user_list[@]})); then
        local selected="${user_list[$((choice - 1))]}"
        IFS=':' read -r name _ <<<"${selected}"
        printf '%s\n' "${name}"
        return 0
    fi
    return 1
}
