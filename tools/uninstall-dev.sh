#!/bin/sh
set -eu

app_install_dir=${CLIPBOX_APP_INSTALL_DIR:-"$HOME/Applications"}
app_destination="$app_install_dir/ClipBox.app"
runtime_bin_dir="$HOME/Library/Application Support/ClipBox/bin"
runtime_cli="$runtime_bin_dir/clipbox"
bundle_id=io.github.LJY0317.ClipBox

remove_cli_link_if_owned() {
    candidate=$1
    if [ -L "$candidate" ] && [ "$(readlink "$candidate")" = "$runtime_cli" ]; then
        rm "$candidate"
        printf 'Removed CLI link: %s\n' "$candidate"
    fi
}

remove_cli_link_if_owned /opt/homebrew/bin/clipbox
remove_cli_link_if_owned /usr/local/bin/clipbox
remove_cli_link_if_owned "$HOME/.local/bin/clipbox"

if [ -d "$app_destination" ]; then
    plist="$app_destination/Contents/Info.plist"
    existing_id=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$plist" 2>/dev/null || true)
    if [ "$existing_id" = "$bundle_id" ]; then
        rm -rf "$app_destination"
        printf 'Removed app: %s\n' "$app_destination"
    else
        printf 'Preserved app with different bundle id at: %s\n' "$app_destination"
    fi
fi

if [ -f "$runtime_cli" ]; then
    rm "$runtime_cli"
    printf 'Removed installed CLI binary: %s\n' "$runtime_cli"
fi

rmdir "$runtime_bin_dir" 2>/dev/null || true

printf '%s\n' 'ClipBox archive history, preferences, private adapters, and other user data were preserved.'
