const fs = require("node:fs");
const path = require("node:path");
const esbuild = require("esbuild");

const resources = path.join(__dirname, "../Resources");
const result = esbuild.buildSync({
  entryPoints: [path.join(__dirname, "editor.js")],
  bundle: true,
  minify: true,
  target: "safari17",
  format: "iife",
  outfile: path.join(resources, "rich-editor.js"),
  legalComments: "eof",
  metafile: true,
});

// Derive notices from the actual bundle, excluding this project's entry point.
const packages = new Map();
for (const input of Object.keys(result.metafile.inputs)) {
  if (!input.split(path.sep).includes("node_modules")) continue;
  let directory = path.dirname(input);
  while (directory !== path.dirname(directory)) {
    const manifest = path.join(directory, "package.json");
    if (fs.existsSync(manifest)) {
      const metadata = JSON.parse(fs.readFileSync(manifest, "utf8"));
      packages.set(`${metadata.name}@${metadata.version}`, {
        directory,
        metadata,
      });
      break;
    }
    directory = path.dirname(directory);
  }
}

let notices = "Matters bundled Markdown editor — third-party notices\n\n";
for (const key of [...packages.keys()].sort()) {
  const { directory, metadata } = packages.get(key);
  const license = fs
    .readdirSync(directory)
    .find((name) => /^licen[sc]e(\.|$)/i.test(name));
  if (!license) throw new Error(`Missing bundled dependency license: ${key}`);
  const repository =
    typeof metadata.repository === "string"
      ? metadata.repository
      : metadata.repository?.url;
  notices += `${metadata.name} ${metadata.version} (${metadata.license})\n`;
  notices += `${metadata.homepage || repository || ""}\n`;
  notices += fs.readFileSync(path.join(directory, license), "utf8") + "\n\n";
}
fs.writeFileSync(path.join(resources, "Editor-LICENSES.txt"), notices.trimEnd() + "\n");
