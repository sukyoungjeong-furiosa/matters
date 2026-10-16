#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
task_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/matters-build.XXXXXX")
trap 'rm -rf "$task_build_dir"' EXIT
output_path="$PWD"
app_path="$task_build_dir/Matters.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
xcrun swiftc -parse-as-library -swift-version 5 -O -target "$(uname -m)-apple-macosx14.0" -module-cache-path "$task_build_dir/cache" Source/Core.swift Source/Workspace.swift Source/App.swift Source/DocumentList.swift Source/FolderGroups.swift Source/MarkdownDocumentEditor.swift Source/MarkdownEditing.swift -o "$app_path/Contents/MacOS/Matters" -framework SwiftUI -framework AppKit -framework WebKit
cp Source/Info.plist "$app_path/Contents/Info.plist"
cp Source/Resources/* "$app_path/Contents/Resources/"
xcrun swift -module-cache-path "$task_build_dir/cache" Source/Icon.swift "$app_path/Contents/Resources/Matters.icns"
xattr -cr "$app_path"
codesign --force --deep --sign - "$app_path"
codesign --verify --deep --strict "$app_path"
# Swap bundles rather than overwrite a binary that may still be running.
update_path="$output_path/.Matters-update.app"
previous_path="$output_path/.Matters-previous.app"
if [ -e "$update_path" ] || [ -e "$previous_path" ]; then
    echo "A previous build staging folder exists; leaving it intact."
    exit 1
fi
ditto --norsrc "$app_path" "$update_path"
if [ -e "$output_path/Matters.app" ]; then mv "$output_path/Matters.app" "$previous_path"; fi
if mv "$update_path" "$output_path/Matters.app"; then
    if [ -e "$previous_path" ]; then rm -rf "$previous_path"; fi
else
    if [ -e "$previous_path" ]; then mv "$previous_path" "$output_path/Matters.app"; fi
    exit 1
fi
xattr -cr "$output_path/Matters.app"
ditto -c -k --keepParent --norsrc "$app_path" "$output_path/Matters.zip"
echo "Built: $output_path/Matters.app"
echo "Archive: $output_path/Matters.zip"
