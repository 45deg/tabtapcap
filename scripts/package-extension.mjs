import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync
} from "node:fs";
import { dirname, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const extensionDir = resolve(repositoryRoot, "apps/extension");
const distDir = resolve(extensionDir, "dist");
const output = resolve(
  repositoryRoot,
  "apps/desktop/src-tauri/resources/tabtapcap-extension.zip"
);

if (!existsSync(resolve(distDir, "manifest.json"))) {
  throw new Error("Extension build output is missing. Run the extension build first.");
}

const packageJson = JSON.parse(
  readFileSync(resolve(extensionDir, "package.json"), "utf8")
);
const manifest = JSON.parse(
  readFileSync(resolve(distDir, "manifest.json"), "utf8")
);
if (manifest.version !== packageJson.version) {
  throw new Error(
    `Extension version mismatch: package.json=${packageJson.version}, manifest=${manifest.version}`
  );
}

mkdirSync(dirname(output), { recursive: true });
rmSync(output, { force: true });
const entries = readdirSync(distDir).sort();
const archive = spawnSync(
  "tar",
  ["-a", "-cf", output, "-C", distDir, ...entries],
  { encoding: "utf8" }
);
if (archive.status !== 0) {
  throw new Error(`Failed to create extension bundle: ${archive.stderr.trim()}`);
}

console.log(`Created ${output} for extension ${packageJson.version}`);
