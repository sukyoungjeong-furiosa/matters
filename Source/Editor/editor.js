import { Editor, Extension, Node } from "@tiptap/core";
import StarterKit from "@tiptap/starter-kit";
import { TableKit } from "@tiptap/extension-table";
import TaskList from "@tiptap/extension-task-list";
import TaskItem from "@tiptap/extension-task-item";
import Image from "@tiptap/extension-image";
import { Markdown } from "@tiptap/markdown";

let editor,
  identity = "",
  source = "",
  prefix = "",
  canonical = "",
  newline = "\n",
  finalNewline = false;
const LocalImage = Image.extend({
  renderHTML({ HTMLAttributes }) {
    const attrs = { ...HTMLAttributes };
    const src = attrs.src || "";
    if (!/^(https?:|data:|matters-asset:)/i.test(src))
      attrs.src =
        "matters-asset://document/" +
        src
          .split("/")
          .map((segment) => {
            try {
              return encodeURIComponent(decodeURIComponent(segment));
            } catch {
              return encodeURIComponent(segment);
            }
          })
          .join("/");
    return ["img", attrs];
  },
});
// Keep HTML blocks opaque: editing nearby text must not discard custom markup.
const RawHTML = Node.create({
  name: "rawHTML",
  group: "block",
  atom: true,
  addAttributes() {
    return { raw: { default: "" } };
  },
  parseHTML() {
    return [
      {
        tag: "div[data-matters-raw]",
        getAttrs: (element) => ({ raw: element.textContent || "" }),
      },
    ];
  },
  renderHTML({ node }) {
    return [
      "div",
      { "data-matters-raw": "", class: "raw-block", contenteditable: "false" },
      ["pre", {}, node.attrs.raw],
    ];
  },
  markdownTokenName: "html",
  parseMarkdown(token) {
    return { type: "rawHTML", attrs: { raw: token.raw || token.text || "" } };
  },
  renderMarkdown(node) {
    return node.attrs.raw;
  },
});
const Shortcuts = Extension.create({
  name: "mattersShortcuts",
  addKeyboardShortcuts() {
    return { "Mod-e": () => this.editor.commands.toggleCodeBlock() };
  },
});
function splitSource(value) {
  const match = value.match(
    /^(?:\uFEFF)?---\r?\n[\s\S]*?\r?\n(?:---|\.\.\.)(?:\r?\n|$)/,
  );
  prefix = match ? match[0] : value.startsWith("\uFEFF") ? "\uFEFF" : "";
  newline = value.includes("\r\n") ? "\r\n" : "\n";
  finalNewline = /\r?\n$/.test(value);
  return value.slice(prefix.length);
}
function currentSource() {
  if (!editor) return source;
  const value = editor.getMarkdown();
  if (value === canonical) return source;
  let body = value.replace(/\r\n/g, "\n").replace(/\n+$/, "");
  if (finalNewline) body += "\n";
  return prefix + body.replace(/\n/g, newline);
}
function publish() {
  const next = currentSource();
  if (next === source) return;
  const base = source;
  source = next;
  canonical = editor.getMarkdown();
  window.webkit?.messageHandlers.mattersEdit.postMessage({
    identity,
    base,
    markdown: next,
  });
}
const actions = [
  ["굵게", "B", (e) => e.chain().focus().toggleBold().run()],
  ["기울임", "I", (e) => e.chain().focus().toggleItalic().run()],
  ["제목", "H2", (e) => e.chain().focus().toggleHeading({ level: 2 }).run()],
  ["목록", "• 목록", (e) => e.chain().focus().toggleBulletList().run()],
  ["체크 목록", "☑", (e) => e.chain().focus().toggleTaskList().run()],
  ["코드 블록", "</>", (e) => e.chain().focus().toggleCodeBlock().run()],
  [
    "표 만들기",
    "표 +",
    (e) =>
      e
        .chain()
        .focus()
        .insertTable({ rows: 3, cols: 3, withHeaderRow: true })
        .run(),
  ],
  [
    "위에 행 추가",
    "↑ 행 +",
    (e) => e.chain().focus().addRowBefore().run(),
    "table",
  ],
  [
    "아래에 행 추가",
    "↓ 행 +",
    (e) => e.chain().focus().addRowAfter().run(),
    "table",
  ],
  [
    "왼쪽 열 추가",
    "← 열 +",
    (e) => e.chain().focus().addColumnBefore().run(),
    "table",
  ],
  [
    "오른쪽 열 추가",
    "→ 열 +",
    (e) => e.chain().focus().addColumnAfter().run(),
    "table",
  ],
  ["행 삭제", "행 −", (e) => e.chain().focus().deleteRow().run(), "table"],
  ["열 삭제", "열 −", (e) => e.chain().focus().deleteColumn().run(), "table"],
  ["표 삭제", "표 삭제", (e) => e.chain().focus().deleteTable().run(), "table"],
];
const toolbar = document.getElementById("toolbar");
for (const [title, label, action, context] of actions) {
  const button = document.createElement("button");
  button.textContent = label;
  button.title = title;
  button.setAttribute("aria-label", title);
  if (context) button.dataset.context = context;
  button.addEventListener("mousedown", (event) => event.preventDefault());
  button.addEventListener("click", () => action(editor));
  toolbar.append(button);
}
function updateToolbar() {
  for (const b of toolbar.querySelectorAll("[data-context]"))
    b.hidden = !editor?.isActive("table");
}
window.renderMarkdown = (value, key) => {
  if (editor && identity === key && source === value) return;
  identity = key;
  source = value;
  const content = splitSource(value);
  document.getElementById("properties").hidden =
    prefix.replace("\uFEFF", "") === "";
  if (editor) {
    editor.destroy();
    document.getElementById("content").replaceChildren();
  }
  editor = new Editor({
    element: document.getElementById("content"),
    extensions: [
      StarterKit.configure({ link: { openOnClick: false } }),
      TableKit,
      TaskList,
      TaskItem.configure({ nested: true }),
      LocalImage,
      RawHTML,
      Markdown,
      Shortcuts,
    ],
    content,
    contentType: "markdown",
    editorProps: {
      attributes: {
        "aria-label": "문서 편집",
        role: "textbox",
        "aria-multiline": "true",
      },
      handleClick(view, pos, event) {
        const link = event.target.closest?.("a");
        if (link && event.metaKey) {
          window.webkit?.messageHandlers.mattersEdit.postMessage({
            identity,
            href: link.getAttribute("href"),
          });
          return true;
        }
        // A plain click should put the caret inside a cell, even when a prior
        // table selection is still active. Drag selection remains native.
        if (
          !event.shiftKey &&
          view.state.selection.$anchorCell &&
          event.target.closest?.("td,th")
        ) {
          editor.commands.setTextSelection(pos);
          return true;
        }
        return false;
      },
      handlePaste(view, event) {
        const text = event.clipboardData?.getData("text/plain") || "";
        if (
          !event.clipboardData?.getData("text/html") &&
          /(^|\n)\s*\|?\s*:?-{3,}.*\|/.test(text)
        ) {
          editor.commands.insertContent(text, { contentType: "markdown" });
          return true;
        }
        return false;
      },
    },
    onUpdate: publish,
    onSelectionUpdate: updateToolbar,
  });
  editor.commands.setContent(content, {
    contentType: "markdown",
    emitUpdate: false,
  });
  canonical = editor.getMarkdown();
  updateToolbar();
  // Shared by native formatting commands and the DOM regression tests.
  window.mattersEditor = editor;
};
window.mattersSource = currentSource;
