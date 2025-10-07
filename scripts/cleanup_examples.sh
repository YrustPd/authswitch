#!/usr/bin/env bash
set -euo pipefail

TARGETS=(
    "ansible-secure-ssh"
    "passlogin"
    "pwauthswitch"
    "ansible-secure-ssh"
)

if [[ "${1:-}" != "--confirm" ]]; then
    cat <<'EOF'
This helper lists optional example directories that are unrelated to authswitch.
Run with --confirm to prompt for deletion of each directory.
Targets:
  - ansible-secure-ssh
  - passlogin
  - pwauthswitch
  - duplicate ansible-secure-ssh
EOF
    exit 0
fi

for dir in "${TARGETS[@]}"; do
    if [[ -d "${dir}" ]]; then
        read -r -p "Delete ${dir}? [y/N]: " reply || reply="n"
        case "${reply}" in
            y|Y)
                rm -rf "${dir}"
                echo "Removed ${dir}"
                ;;
            *)
                echo "Skipped ${dir}"
                ;;
        esac
    else
        echo "Not found: ${dir}"
    fi
done

echo "Cleanup complete."
