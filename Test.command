#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
task_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/matters-tests.XXXXXX")
trap 'rm -rf "$task_test_dir"' EXIT
xcrun swiftc -parse-as-library -swift-version 5 -module-cache-path "$task_test_dir/cache" Source/Core.swift Source/Tests.swift -o "$task_test_dir/CoreTests"
"$task_test_dir/CoreTests"
xcrun swiftc -parse-as-library -swift-version 5 -D MODEL_TEST -module-cache-path "$task_test_dir/cache" Source/Core.swift Source/Workspace.swift Source/App.swift Source/DocumentList.swift Source/FolderGroups.swift Source/MarkdownDocumentEditor.swift Source/MarkdownEditing.swift Source/ModelTests.swift -o "$task_test_dir/ModelTests" -framework WebKit
"$task_test_dir/ModelTests"
xcrun swiftc -parse-as-library -swift-version 5 -module-cache-path "$task_test_dir/cache" Source/MarkdownEditing.swift Source/EditingTests.swift -o "$task_test_dir/EditingTests"
"$task_test_dir/EditingTests"
