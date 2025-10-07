#!/usr/bin/env bash
# Allow only the specified user to authenticate with a password.
authswitch --yes allow-password-for-user "$1"
