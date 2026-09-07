import { readFile } from "node:fs/promises";
import { test, expect } from "./fixtures.mjs";

async function ready(environment, id) {
  await expect.poll(async () => (await environment.getSession(id)).state).toBe("ready");
  return environment.getSession(id);
}

test("record, transcribe, edit without losing drafts, export, reload and delete", async ({ page, capture, environment }) => {
  const id = await capture.start("E2E 編集と保存");
  expect((await capture.stop()).ok).toBe(true);
  const session = await ready(environment, id);
  expect(session.audio_gap).toBe(false);
  expect(session.utterances).toHaveLength(2);
  await page.goto(`${environment.viewerOrigin}/?session=${id}`);
  const editors = page.getByRole("textbox", { name: /の発話$/ });
  await expect(editors).toHaveCount(2);
  await editors.nth(0).fill("保存した文章。");
  await editors.nth(1).fill("まだ保存していない文章。");
  await page.locator(".utterance").nth(1).getByRole("checkbox").check();
  await page.locator(".utterance").nth(0).getByRole("button", { name: "変更を保存" }).click();
  await expect(page.locator(".utterance").nth(0).getByRole("button", { name: /保存/ })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "変更を保存" })).toHaveCount(1);
  await expect(editors.nth(1)).toHaveValue("まだ保存していない文章。");
  await expect(page.locator(".utterance").nth(1).getByRole("checkbox")).toBeChecked();
  await page.getByRole("button", { name: "変更を保存" }).click();
  await expect(page.getByRole("button", { name: "変更を保存" })).toHaveCount(0);
  for (const format of ["TXT", "VTT", "JSON"]) {
    const downloadPromise = page.waitForEvent("download");
    await page.getByRole("button", { name: format, exact: true }).click();
    const download = await downloadPromise;
    const text = await readFile(await download.path(), "utf8");
    expect(text).toContain("保存した文章。");
    expect(text).toContain("まだ保存していない文章。");
    if (format === "VTT") expect(text).toContain("WEBVTT");
    if (format === "JSON") expect(() => JSON.parse(text)).not.toThrow();
  }
  await page.reload();
  await expect(editors.nth(1)).toHaveValue("まだ保存していない文章。");
  await page.locator(".utterance").nth(0).getByRole("button", { name: "0:00" }).click();
  await expect.poll(() => page.locator("audio").evaluate((audio) => audio.currentTime)).toBeGreaterThan(0.1);
  await page.getByRole("button", { name: "削除", exact: true }).click();
  await page.getByRole("alertdialog").getByRole("button", { name: "削除する" }).click();
  await expect(page.getByText("録音を削除しました。", { exact: true })).toBeVisible();
  expect((await fetch(`${environment.apiOrigin}/api/v1/sessions/${id}`)).status).toBe(404);
});

test("stop while disconnected retains and resends all captured frames", async ({ capture, environment }) => {
  const id = await capture.start("E2E 切断中の停止");
  capture.disconnect();
  const levels = await capture.page.evaluate(() => window.captureHarness.levels);
  await expect.poll(() => capture.page.evaluate(() => window.captureHarness.levels)).toBeGreaterThanOrEqual(levels + 5);
  const failed = await capture.stop();
  expect(failed.ok).toBe(false);
  expect(failed.message).toContain("保持");
  const capturedFrames = await capture.page.evaluate(() => window.captureHarness.levels);
  capture.reconnect();
  expect((await capture.stop()).ok).toBe(true);
  const session = await ready(environment, id);
  expect(session.total_samples).toBe(capturedFrames * Math.round(session.sample_rate / 10));
  expect(session.audio_gap).toBe(false);
  const wav = Buffer.from(await (await fetch(`${environment.apiOrigin}/api/v1/sessions/${id}/audio`)).arrayBuffer());
  expect(wav.toString("ascii", 0, 4)).toBe("RIFF");
  expect(wav.length).toBeGreaterThan(64_000);
  expect(wav.subarray(44).some((byte) => byte !== 0)).toBe(true);
});

test("track end notifies idle and allows a subsequent recording", async ({ capture, environment }) => {
  const id = await capture.start("E2E タブ終了");
  await capture.page.evaluate(() => window.captureHarness.endTrack());
  await expect.poll(() => capture.page.evaluate(() => window.captureHarness.states.at(-1)?.status)).toBe("idle");
  await ready(environment, id);
  const second = await capture.start("E2E 次の録音");
  expect(second).not.toBe(id);
  expect((await capture.stop()).ok).toBe(true);
  await ready(environment, second);
});

test("late detail response cannot replace the selected recording", async ({ page, capture, environment }) => {
  const first = await capture.start("E2E 録音A");
  expect((await capture.stop()).ok).toBe(true);
  await ready(environment, first);
  const second = await capture.start("E2E 録音B");
  expect((await capture.stop()).ok).toBe(true);
  await ready(environment, second);
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  const held = [];
  await page.route(`**/api/v1/sessions/${first}`, async (route) => {
    const response = await route.fetch();
    held.push(response);
    await gate;
    await route.fulfill({ response });
  });
  try {
    await page.goto(`${environment.viewerOrigin}/?session=${first}`);
    await expect.poll(() => held.length).toBeGreaterThan(0);
    await page.getByRole("button", { name: /E2E 録音B/ }).click();
    await expect(page.getByRole("textbox", { name: "録音タイトル" })).toHaveValue("E2E 録音B");
    const completed = page.waitForResponse((response) => response.url().endsWith(`/api/v1/sessions/${first}`));
    release();
    await (await completed).finished();
    await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    await expect(page.getByRole("textbox", { name: "録音タイトル" })).toHaveValue("E2E 録音B");
  } finally {
    release();
    await page.unrouteAll({ behavior: "wait" });
  }
});

test("Viewer reconnects its event stream and displays the completed transcript", async ({ page, capture, environment }) => {
  let offline = false;
  let connections = 0;
  const sockets = [];
  await page.routeWebSocket("**/ws/v1/events?*", (route) => {
    connections++;
    if (offline) { route.close(); return; }
    sockets.push({ route, upstream: route.connectToServer() });
  });
  const id = await capture.start("E2E イベント再接続");
  await page.goto(`${environment.viewerOrigin}/?session=${id}`);
  await expect(page.getByRole("textbox", { name: "録音タイトル" })).toHaveValue("E2E イベント再接続");
  await expect.poll(() => connections).toBeGreaterThan(0);
  offline = true;
  for (const { route, upstream } of sockets.splice(0)) { upstream.close(); route.close(); }
  const before = connections;
  expect((await capture.stop()).ok).toBe(true);
  await ready(environment, id);
  offline = false;
  await expect.poll(() => connections).toBeGreaterThan(before);
  await expect(page.getByRole("textbox", { name: /の発話$/ })).toHaveCount(2);
});
