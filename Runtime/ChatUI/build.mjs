import { build } from "esbuild";
import {
  mkdir,
  writeFile,
  copyFile,
  readFile,
  readdir,
} from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";
const root = path.dirname(fileURLToPath(import.meta.url));
const out = path.resolve(root, "../../Sources/KnarrUI/Resources/ChatWeb");
await mkdir(out, { recursive: true });
const bundled = await build({
  metafile: true,
  entryPoints: [path.join(root, "src/app.tsx")],
  outfile: path.join(out, "app.js"),
  bundle: true,
  minify: true,
  format: "iife",
  target: ["safari17"],
  define: { "process.env.NODE_ENV": '"production"' },
  legalComments: "linked",
});
await copyFile(path.join(root, "src/style.css"), path.join(out, "app.css"));
await writeFile(
  path.join(out, "index.html"),
  '<!doctype html><html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src \'none\'; script-src \'self\'; style-src \'self\' \'unsafe-inline\'; img-src data: chat-image:; connect-src \'none\'; font-src \'self\'; frame-src \'none\'; base-uri \'none\'; form-action \'none\'"><link rel="stylesheet" href="app.css"><title>Knarr 대화</title></head><body><div id="root"></div><script src="app.js"></script></body></html>',
);
const compiled = await build({
  entryPoints: [path.join(root, "src/library.tsx")],
  bundle: true,
  platform: "node",
  format: "esm",
  packages: "external",
  write: false,
});
// Keep module beside node_modules for deterministic dependency resolution; this is a build intermediate.
const promptModule = path.join(root, ".prompt-build.mjs");
await writeFile(promptModule, compiled.outputFiles[0].text);
try {
  const { prompt } = await import(promptModule + "?" + Date.now());
  const dest = path.resolve(
    root,
    "../../Sources/KnarrCore/Resources/stallari/chat-ui.txt",
  );
  await writeFile(dest, prompt + "\n");
} finally {
  const { unlink } = await import("node:fs/promises");
  await unlink(promptModule);
}

const packages = new Map();
for (const input of Object.keys(bundled.metafile.inputs)) {
  if (!input.includes("node_modules/")) continue;
  let directory = path.dirname(path.resolve(input));
  while (directory.includes("node_modules")) {
    try {
      const pkg = JSON.parse(
        await readFile(path.join(directory, "package.json"), "utf8"),
      );
      if (pkg.name) {
        packages.set(pkg.name, { ...pkg, directory });
        break;
      }
    } catch {}
    directory = path.dirname(directory);
  }
}
let notices = "Knarr chat renderer — third-party notices\n";
for (const pkg of [...packages.values()].sort((a, b) =>
  a.name.localeCompare(b.name),
)) {
  notices += `\n${pkg.name} ${pkg.version} (${typeof pkg.license === "string" ? pkg.license : "see license"})\n`;
  const files = (await readdir(pkg.directory)).filter((n) =>
    /^(license|licence|copying|notice)(\.|$)/i.test(n),
  );
  for (const file of files)
    try {
      notices +=
        (await readFile(path.join(pkg.directory, file), "utf8")) + "\n";
    } catch {}
}
await writeFile(path.join(out, "THIRD_PARTY_NOTICES.txt"), notices.trimEnd() + "\n");
