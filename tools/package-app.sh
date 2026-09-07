#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
destination=${1:-"$project_root/dist/ClipBox.app"}
bundle_id=io.github.LJY0317.ClipBox

assert_replaceable_app() {
    app=$1
    if [ ! -e "$app" ]; then
        return
    fi
    plist="$app/Contents/Info.plist"
    if [ ! -f "$plist" ]; then
        printf '%s\n' "Refusing to replace existing non-ClipBox path: $app" >&2
        exit 1
    fi
    existing_id=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$plist" 2>/dev/null || true)
    if [ "$existing_id" != "$bundle_id" ]; then
        printf '%s\n' "Refusing to replace app with bundle id '$existing_id': $app" >&2
        exit 1
    fi
}

cd "$project_root"

swift build -c release --product ClipBoxApp >&2
bin_dir=$(swift build -c release --show-bin-path)
source_binary="$bin_dir/ClipBoxApp"

if [ ! -x "$source_binary" ]; then
    printf '%s\n' "ClipBoxApp release binary was not produced at $source_binary" >&2
    exit 1
fi

assert_replaceable_app "$destination"
rm -rf "$destination"
mkdir -p "$destination/Contents/MacOS" "$destination/Contents/Resources"

cp "$source_binary" "$destination/Contents/MacOS/ClipBox"
chmod 755 "$destination/Contents/MacOS/ClipBox"
cp "$project_root/apps/macos/Info.plist" "$destination/Contents/Info.plist"
cp "$project_root/LICENSE" "$destination/Contents/Resources/LICENSE.txt"

/usr/bin/plutil -lint "$destination/Contents/Info.plist" >/dev/null
/usr/bin/codesign --force --sign - --timestamp=none "$destination"
/usr/bin/codesign --verify --strict "$destination"

printf '%s\n' "$destination"
