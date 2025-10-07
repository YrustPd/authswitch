# authswitch

authswitch is a standalone administrative tool for auditing and managing SSH password authentication policies on Debian/Ubuntu and RHEL/CentOS style systems. It keeps `sshd_config` changes small, logged, and reversible so administrators can toggle password or root-login access without surprises.

## Highlights
- Interactive TUI and non-interactive CLI for automation
- Idempotent edits with automatic, timestamped backups and rollback support
- Dry-run previews, syntax validation, and service reload detection
- Per-user password allow-list implemented with dedicated `Match User` blocks
- Audit logging with simple rotation in `/var/log/authswitch/authswitch.log`
- Install and uninstall scripts ready for production workflows

## Installation
Deploy the latest release with a single command:

```bash
curl -fsSL https://raw.githubusercontent.com/YrustPd/authswitch/main/install.sh | bash
```

The installer will escalate with `sudo` when required, update and upgrade system packages (apt/dnf/yum), install prerequisites such as OpenSSH server, and publish `authswitch` to `/usr/local/bin` with supporting libraries under `/usr/local/share/authswitch`. Backup and log directories are created automatically.

## Uninstallation
```bash
cd authswitch
sudo ./uninstall.sh
```

Add `--restore-last` to copy the newest backup from `/etc/authswitch/backups` back to `/etc/ssh/sshd_config` before removing files. Use `--yes` to skip prompts.

## Usage
Run `authswitch --help` for the full command listing:

```
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
```

Global options:
- `--dry-run` shows the planned diff without writing files or reloading services
- `--yes` accepts confirmations automatically
- `--no-color` disables ANSI color when piping output
- `--log <path>` points logging to a custom location
- `--version` prints the tool version

### Interactive session
```
sudo authswitch interactive
```
The menu summarizes current `PasswordAuthentication`, `PermitRootLogin`, and any per-user allowances. Each action requests confirmation unless `--yes` was provided. Press `q` or choose option `9` to exit.

### Non-interactive examples
- Enable global password login: `sudo authswitch --yes enable-password-login`
- Disable root password login: `sudo authswitch --yes disable-root-password`
- Permit a specific user (root in this example): `sudo authswitch --yes allow-password-for-user root`

See the `examples/` directory for one-line automation snippets.

## Rollback and backups
- Backups live in `/etc/authswitch/backups` by default (`AUTH_BACKUP_DIR` env overrides help during testing).
- List backups with `sudo authswitch list-backups`.
- Restore a specific file: `sudo authswitch rollback /etc/authswitch/backups/sshd_config.20240101010101`.
- Every change (except dry-run) generates a new backup and writes an audit entry.

## Security considerations
- authswitch requires root unless `TEST_SSHD_CONFIG` is set for dry-run testing. This keeps real edits limited to administrators.
- Before committing changes, the tool runs `sshd -t` to verify syntax (skipped when `TEST_SSHD_CONFIG` is used).
- Changes are minimal: unrelated comments and match blocks remain intact.
- The CLI warns about external PAM/MFA enforcement; disabling password authentication here does not remove other account policies.
- Service reload detection prefers `systemctl` and falls back to SysV init scripts; in test mode it prints the intended action instead of touching services.

## Supported distributions
- Debian 10+
- Ubuntu 20.04+
- RHEL 8+
- CentOS Stream 8+
- Rocky Linux / AlmaLinux (RHEL derivatives)

Other Linux distributions may work if OpenSSH uses the standard `/etc/ssh/sshd_config` path. The installer prints a warning when the system is outside the tested families.

## Troubleshooting
- Run `sudo authswitch --dry-run disable-password-login` to inspect upcoming edits safely.
- Check `/var/log/authswitch/authswitch.log` for structured audit entries. The log rotates automatically at ~512 KB.
- If `sshd -t` fails, review the reported line numbers and roll back using the latest backup.
- Ensure PAM or LDAP policies align with your desired password restrictions; authswitch leaves those layers untouched.
- Use `--no-color` when capturing output for scripts that expect plain text.

## Testing
All tests run in dry-run mode and never touch the live `sshd_config`:
```bash
bash tests/run.sh
```

The harness sets `TEST_SSHD_CONFIG` to a temporary copy of `tests/fixtures/sshd_config`. This bypasses the root requirement and skips service reloads, making the suite safe on developer machines and CI agents.

Continuous integration is provided via `.github/workflows/ci.yml`, which runs ShellCheck and the integration tests on every push or pull request.

## Maintenance utilities
- `scripts/cleanup_examples.sh` lists optional directories (`ansible-secure-ssh`, `passlogin`, `pwauthswitch`, duplicate `ansible-secure-ssh`) and removes them only when the script is invoked with `--confirm`. The main project never depends on these examples.
- The tool operates entirely offline, using existing system binaries. No external repositories are cloned, vendored, or dynamically sourced.

## Repository
- Author: authswitch
- URL: https://github.com/YrustPd/authswitch.git
- License: already created in this repo

## Changelog
- Initial release by authswitch
