import { test as base, expect } from "@playwright/test";
import { spawn } from "node:child_process";
import { mkdtemp, mkdir, writeFile, rm } from "node:fs/promises";
import { createServer as createNetServer } from "node:net";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const repo = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const desktop = join(repo, "apps/desktop");
const desktopRequire = createRequire(join(desktop, "package.json"));
const { createServer } = await import(pathToFileURL(desktopRequire.resolve("vite")).href);

async function freePort() {
  const server = createNetServer();
  await new Promise((resolve, reject) => { server.once("error", reject); server.listen(0, "127.0.0.1", resolve); });
  const port = server.address().port;
  await new Promise((resolve) => server.close(resolve));
  return port;
}

async function stopChild(child) {
  if (child.exitCode !== null || child.signalCode !== null) return;
  await new Promise((resolve) => {
    const timer = setTimeout(() => child.kill("SIGKILL"), 3_000);
    child.once("exit", () => { clearTimeout(timer); resolve(); });
    child.kill("SIGTERM");
  });
}

export const test = base.extend({
  environment: async ({}, use, testInfo) => {
    const directory = await mkdtemp(join(tmpdir(), "tabtapcap-e2e-"));
    const data = join(directory, "data");
    const port = await freePort();
    const apiOrigin = `http://127.0.0.1:${port}`;
    let child;
    let vite;
    let log = "";
    try {
      await mkdir(data);
      await writeFile(join(data, "config.json"), JSON.stringify({
        transcription: { model_id: "apple-speech", language: "ja" },
        formatting: { sentence_pause_ms: 500, paragraph_pause_ms: 1000 }
      }));
      const helper = join(directory, "speech-fixture");
      await writeFile(helper, `#!/usr/bin/env node
// Deterministic recognizer fixture: no real ASR or model download.
if (process.argv[2] === "--status") {
  console.log(JSON.stringify({available:true,supported:true,installed:true,asset_status:"installed",message:null}));
} else {
  const fs = require("node:fs");
  const wav = fs.readFileSync(process.argv[2]);
  if (wav.toString("ascii",0,4) !== "RIFF" || wav.length < 48044) process.exit(2);
  setTimeout(() => console.log(JSON.stringify({segments:[
    {text:"最初の検証用発話",start_ms:100,end_ms:300},
    {text:"二番目の検証用発話",start_ms:900,end_ms:1200}
  ]})), 300);
}
`, { mode: 0o755 });
      child = spawn(join(repo, "target/debug/tabtapcap-server"), [], {
        cwd: repo,
        env: {
          ...process.env,
          TABTAPCAP_PORT: String(port),
          TABTAPCAP_DATA_DIR: data,
          TABTAPCAP_MODELS_DIR: join(directory, "models"),
          TABTAPCAP_APPLE_SPEECH_PATH: helper
        },
        stdio: ["ignore", "pipe", "pipe"]
      });
      child.stdout.on("data", (chunk) => { log = (log + chunk).slice(-1_000_000); });
      child.stderr.on("data", (chunk) => { log = (log + chunk).slice(-1_000_000); });
      let launchError;
      child.on("error", (error) => { launchError = error; });
      await expect.poll(async () => {
        if (launchError) throw launchError;
        if (child.exitCode !== null) throw new Error(`Server exited: ${log}`);
        return fetch(`${apiOrigin}/api/v1/health`, { signal: AbortSignal.timeout(1000) })
          .then((response) => response.ok).catch(() => false);
      }, { timeout: 15_000 }).toBe(true);
      vite = await createServer({
        configFile: join(desktop, "vite.config.ts"), root: desktop, logLevel: "error",
        server: {
          host: "127.0.0.1", port: 0, strictPort: true, hmr: false,
          fs: { allow: [repo] },
          proxy: { "/api": apiOrigin, "/ws": { target: apiOrigin.replace("http", "ws"), ws: true } }
        }
      });
      await vite.listen();
      const viewerOrigin = `http://127.0.0.1:${vite.httpServer.address().port}`;
      const getSession = async (id) => {
        const response = await fetch(`${apiOrigin}/api/v1/sessions/${id}`, { signal: AbortSignal.timeout(5000) });
        if (!response.ok) throw new Error(`Session request: HTTP ${response.status}`);
        return response.json();
      };
      await use({ apiOrigin, viewerOrigin, repo, getSession });
    } finally {
      if (vite) await vite.close();
      if (child) await stopChild(child);
      await testInfo.attach("server.log", { body: log || "No server output", contentType: "text/plain" });
      await rm(directory, { recursive: true, force: true });
    }
  },
  capture: async ({ context, environment }, use) => {
    const page = await context.newPage();
    let offline = false;
    const sockets = [];
    await page.routeWebSocket("**/ws/v1/capture", (route) => {
      if (offline) { route.close(); return; }
      const upstream = route.connectToServer();
      sockets.push({ route, upstream });
    });
    const query = new URLSearchParams({ api: environment.apiOrigin, repo });
    await page.goto(`${environment.viewerOrigin}/@fs${repo}/tests/e2e/capture.html?${query}`);
    await page.waitForFunction(() => window.captureHarness?.ready);
    await use({
      page,
      start: async (title) => {
        const state = await page.evaluate((title) => window.captureHarness.start(title), title);
        await expect.poll(() => page.evaluate(() => window.captureHarness.levels)).toBeGreaterThanOrEqual(20);
        return state.sessionId;
      },
      stop: () => page.evaluate(() => window.captureHarness.stop()),
      disconnect: () => {
        offline = true;
        for (const { route, upstream } of sockets.splice(0)) {
          upstream.close();
          route.close();
        }
      },
      reconnect: () => { offline = false; }
    });
    await page.close();
  }
});

export { expect };
