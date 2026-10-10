#!/bin/sh
#
# sudo-integration.sh
# NotchHelper
#
# SPDX-License-Identifier: GPL-3.0-only
#
# Turns Face Unlock for sudo on or off. NotchHelper runs it as root after
# the user approves the macOS administrator prompt:
#
#   sudo-integration.sh install <pam_notch.so> <requirement file>
#   sudo-integration.sh uninstall
#
# Installing copies the PAM module and the code requirement it checks
# NotchHelper against, then adds one line to /etc/pam.d/sudo_local, the
# file macOS keeps for local sudo changes and leaves alone during updates.
#
# A PAM module sudo can't load would stop sudo from working at all, so
# installing checks the folders first, then makes sure sudo still starts,
# and puts everything back the way it was if it doesn't. Uninstalling
# doesn't need sudo, so it works even if sudo is broken.

set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin

module_dir=/usr/local/lib/pam
module=$module_dir/pam_notch.so.2
requirement_dir=/usr/local/etc
requirement=$requirement_dir/notch-sudo.requirement
config=/etc/pam.d/sudo_local
template=/etc/pam.d/sudo_local.template
backup=$config.notch-backup
line="auth       sufficient     $module"

fail() {
    echo "$*" >&2
    exit 1
}

# OpenPAM only loads modules from folders that only root can change.
check_folder() {
    folder=$1
    while [ "$folder" != "/" ]; do
        set -- $(stat -f '%u %Lp' "$folder")
        [ "$1" = 0 ] || fail "$folder isn't owned by root."
        case $2 in
            *[2367]? | *[2367]) fail "$folder can be changed by users other than root." ;;
        esac
        folder=$(dirname "$folder")
    done
}

# Takes Notch's line out of sudo_local, leaving the rest as it is.
remove_config_line() {
    if [ -f "$config" ] && grep -q 'pam_notch\.so' "$config"; then
        new_config=$(mktemp /tmp/notch-sudo.XXXXXX)
        grep -v 'pam_notch\.so' "$config" > "$new_config" || true
        install -o root -g wheel -m 444 "$new_config" "$config"
        rm -f "$new_config"
    fi
}

# Undoes a failed install: sudo_local goes back to how it was (or loses
# the line an earlier install added), and the module goes away.
restore() {
    if [ "$changed_config" = 1 ]; then
        if [ -f "$backup" ]; then
            mv -f "$backup" "$config"
        else
            rm -f "$config"
        fi
    else
        remove_config_line
    fi
    rm -f "$module" "$requirement" "$backup"
}

install_integration() {
    source_module=$1
    source_requirement=$2
    [ -f "$source_module" ] || fail "The sudo module is missing from Notch."
    [ -s "$source_requirement" ] || fail "Notch's code requirement is missing."

    install -d -o root -g wheel -m 755 "$module_dir" "$requirement_dir"
    check_folder "$module_dir"
    check_folder "$requirement_dir"
    install -o root -g wheel -m 444 "$source_module" "$module"
    install -o root -g wheel -m 444 "$source_requirement" "$requirement"

    rm -f "$backup"
    changed_config=0
    if ! grep -q 'pam_notch\.so' "$config" 2>/dev/null; then
        changed_config=1
        [ -f "$config" ] && cp -p "$config" "$backup"
        source=$config
        [ -f "$source" ] || source=$template
        [ -f "$source" ] || source=/dev/null
        new_config=$(mktemp /tmp/notch-sudo.XXXXXX)
        # Notch goes first among the auth lines, so it's asked before Touch
        # ID, and everything after it still works if Notch says no.
        awk -v line="$line" '
            !added && /^[[:space:]]*auth/ { print line; added = 1 }
            { print }
            END { if (!added) print line }
        ' "$source" > "$new_config"
        install -o root -g wheel -m 444 "$new_config" "$config"
        rm -f "$new_config"
    fi

    # sudo starts a PAM session even for root, which loads every module in
    # its configuration, ours included. If that fails, undo everything.
    if ! /usr/bin/sudo -n /usr/bin/true >/dev/null 2>&1; then
        restore
        fail "sudo didn't start with Face Unlock turned on, so nothing was changed."
    fi
    rm -f "$backup"
}

uninstall_integration() {
    # The configuration goes first, so sudo never points at a missing module.
    remove_config_line
    rm -f "$module" "$requirement" "$backup"
}

[ "$(id -u)" = 0 ] || fail "This has to run as root."
case ${1:-} in
    install)
        [ $# = 3 ] || fail "usage: $0 install <module> <requirement>"
        install_integration "$2" "$3"
        ;;
    uninstall)
        uninstall_integration
        ;;
    *)
        fail "usage: $0 install <module> <requirement> | uninstall"
        ;;
esac
