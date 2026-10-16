# Matters

A small native macOS application for keeping engineering work in ordinary Markdown files and directories. SwiftUI and AppKit provide the desktop interface; a bundled Tiptap editor provides editable Markdown rendering and tables.

Documents remain independent of the app. Folder groups, pinned documents, saved searches, and view preferences live in local `UserDefaults`, scoped to each workspace. The app adds no required document metadata or workspace database.

## Development

Requirements: macOS 14 or later and the Xcode command-line tools.

```sh
./Test.command
./Build.command
```

The build produces a locally signed `Matters.app` and `Matters.zip` for the host architecture. Build products and local usage notes are excluded from version control. This is an ad hoc build, not a notarized distribution.

The JavaScript bundle and third-party notices are checked in, so a native build does not need Node.js or a package download. To change the embedded editor, use Node.js 24.15 or later and the pnpm version pinned in its manifest:

```sh
pnpm --dir Source/Editor install --frozen-lockfile --ignore-scripts
pnpm --dir Source/Editor build
pnpm --dir Source/Editor test
```

GitHub Actions repeats the editor checks, native regression tests, and app build. Editor builds also verify that all bundled dependencies have license notices.

## Code layout

| Location | Responsibility |
| --- | --- |
| `Source/Core.swift` | File scanning, guarded file writes, search rules, and folder-group values |
| `Source/Workspace.swift` | Document lifecycle, editing state, local preferences, and app actions |
| `Source/App.swift` | App lifecycle, menus, and SwiftUI screens |
| `Source/DocumentList.swift` | Native table selection, drag handling, and document context menus |
| `Source/FolderGroups.swift` | Folder-group editing and membership controls |
| `Source/MarkdownDocumentEditor.swift` | WebKit bridge and workspace-confined local image loading |
| `Source/MarkdownEditing.swift` | Unicode-aware Markdown transformations for the source editor |
| `Source/Editor/` | Bundled editor source, dependency lockfile, build script, and DOM tests |

The native tests cover file preservation, external-edit conflicts, document moves, selection behavior, search rules, exclusive folder groups, pin ordering, and Unicode selections. The DOM tests cover Markdown round trips, table editing, frontmatter, line endings, opaque HTML blocks, and editor undo/redo.

## Boundaries

- UI text remains Korean; code comments and development documentation are English.
- Rendered edits may normalize Markdown whitespace and syntax. Opening a document or switching modes alone preserves its original text.
- Group membership and pins are local preferences. In-app document moves preserve pins; external renames require reassignment.
- Local image access is restricted to the selected workspace. The editor is bundled and uses no remote script CDN.

Third-party attribution is in [`Source/Resources/Editor-LICENSES.txt`](Source/Resources/Editor-LICENSES.txt). No personal documents, user settings, or application bundles are included in this repository.
