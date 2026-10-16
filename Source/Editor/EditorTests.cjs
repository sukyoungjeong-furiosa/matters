const { JSDOM } = require("jsdom"),
  fs = require("fs"),
  path = require("path"),
  assert = require("assert/strict");
const dom = new JSDOM(
  fs.readFileSync(path.join(__dirname, "../Resources/preview.html"), "utf8"),
  {
    runScripts: "outside-only",
    pretendToBeVisual: true,
    url: "https://local.invalid/",
  },
);
const w = dom.window;
w.scrollBy = () => {};
w.Range.prototype.getClientRects = () => [];
w.Range.prototype.getBoundingClientRect = () => ({
  top: 0,
  left: 0,
  bottom: 0,
  right: 0,
});
const messages = [];
w.webkit = {
  messageHandlers: { mattersEdit: { postMessage: (m) => messages.push(m) } },
};
w.eval(
  fs.readFileSync(path.join(__dirname, "../Resources/rich-editor.js"), "utf8"),
);
const sample =
  "---\nanything: free\n---\n# Matter\n\n| Perspective | Checklist | Notes |\n|---|---|---|\n| **① Value & Ownership** | Value — what does this create? | |\n| | Priority — relevance to objectives and milestones? | |\n| **② Decision & Action** | Execution — what needs to happen? | |\n\n- [ ] Check\n\n```swift\nlet x = 1\n```\n";
w.renderMarkdown(sample, "test");
assert.equal(w.mattersSource(), sample);
assert.equal(messages.length, 0);
assert.equal(w.document.querySelectorAll("table").length, 1);
assert.equal(w.document.querySelectorAll("td").length, 9);
assert.equal(
  w.document.querySelector("strong").textContent,
  "① Value & Ownership",
);
let ed = w.mattersEditor,
  pos;
ed.state.doc.descendants((node, p) => {
  if (
    pos === undefined &&
    node.type.name === "tableCell" &&
    node.textContent === ""
  )
    pos = p + 2;
});
ed.commands.setTextSelection(pos);
ed.commands.insertContent("Direct input");
assert.match(w.mattersSource(), /Direct input/);
assert.ok(w.mattersSource().startsWith("---\nanything: free\n---\n"));
assert.equal(messages.length, 1);
assert.equal(messages[0].base, sample);
ed.commands.setHardBreak();
ed.commands.insertContent("Second line");
assert.match(w.mattersSource(), /<br>/);
ed.commands.addRowAfter();
assert.equal(w.document.querySelectorAll("tr").length, 5);
ed.commands.addColumnAfter();
assert.equal(w.document.querySelectorAll("th").length, 4);
let headerPosition;
ed.state.doc.descendants((node, position) => {
  if (headerPosition === undefined && node.type.name === "tableHeader")
    headerPosition = position + 2;
});
ed.commands.setTextSelection(headerPosition);
ed.commands.deleteColumn();
assert.equal(w.document.querySelectorAll("th").length, 3);
ed.commands.addRowAfter();
ed.commands.deleteRow();
assert.equal(w.document.querySelectorAll("tr").length, 5);
const saved = w.mattersSource();
w.renderMarkdown(saved, "second");
assert.match(w.document.querySelector("table").textContent, /Direct input/);
assert.equal(messages.at(-1).markdown, saved); // load is read-only
w.renderMarkdown("hello\r\n", "crlf");
w.mattersEditor.commands.insertContent("x");
assert.ok(w.mattersSource().endsWith("\r\n"));
assert.ok(!/(?<!\r)\n/.test(w.mattersSource()));
w.renderMarkdown("", "paste");
const e = w.mattersEditor;
let intercepted = e.view.someProp("handlePaste", (fn) =>
  fn(e.view, {
    clipboardData: {
      getData: (t) =>
        t === "text/plain" ? "| A | B |\n|---|---|\n| x | y |" : "",
    },
  }),
);
assert.ok(intercepted);
assert.equal(w.document.querySelectorAll("td").length, 2);
assert.match(w.mattersSource(), /x/);
w.renderMarkdown(
  "<details><summary>Details</summary>custom HTML</details>\n\nBody\n",
  "html",
);
assert.equal(w.document.querySelectorAll("details").length, 0);
assert.match(w.document.querySelector(".raw-block").textContent, /custom HTML/);
w.mattersEditor.commands.setTextSelection(
  w.mattersEditor.state.doc.content.size - 1,
);
w.mattersEditor.commands.insertContent("More");
assert.match(
  w.mattersSource(),
  /<details><summary>Details<\/summary>custom HTML<\/details>/,
);
w.renderMarkdown(
  '# Test\n\n- [x] done\n\n![local](image%20file.png)\n\n[link](other.md)\n\n```swift\nlet x = "a|b"\n```\n',
  "mixed",
);
assert.equal(w.document.querySelector("input[type=checkbox]").checked, true);
assert.equal(
  w.document.querySelector("img").getAttribute("src"),
  "matters-asset://document/image%20file.png",
);
assert.equal(w.document.querySelector("a").getAttribute("href"), "other.md");
const beforeUndo = w.mattersSource();
w.mattersEditor.commands.insertContent("hello");
assert.notEqual(w.mattersSource(), beforeUndo);
w.mattersEditor.commands.undo();
assert.equal(w.mattersEditor.getText().includes("hello"), false);
w.mattersEditor.commands.redo();
assert.equal(w.mattersEditor.getText().includes("hello"), true);
console.log(
  "PASS: load without rewrite, table cells, bold, frontmatter, live edits, line breaks, row/column add/delete, reload, CRLF, Markdown table paste, opaque HTML, tasks, images, links, undo/redo",
);
dom.window.close();
