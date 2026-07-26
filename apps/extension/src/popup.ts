import type { BackgroundMessage, RecordingState } from "./protocol";

const statusElement = document.querySelector<HTMLParagraphElement>("#status")!;
const detailElement = document.querySelector<HTMLParagraphElement>("#detail")!;
const dotElement = document.querySelector<HTMLSpanElement>("#status-dot")!;
const primaryButton = document.querySelector<HTMLButtonElement>("#primary")!;
const viewerButton = document.querySelector<HTMLButtonElement>("#viewer")!;

let state: RecordingState = { status: "idle" };
let serverReady = false;
let language: "ja" | "auto" = "ja";
let timer: number | null = null;

function render(): void {
  dotElement.className = "status-dot";
  primaryButton.classList.remove("stop");
  primaryButton.disabled = false;
  if (state.status === "recording" || state.status === "reconnecting") {
    dotElement.classList.add("recording");
    statusElement.textContent =
      state.status === "recording" ? "録音中" : "再接続しています…";
    const elapsed = Math.max(0, Date.now() - state.startedAt);
    const minutes = Math.floor(elapsed / 60_000);
    const seconds = Math.floor((elapsed % 60_000) / 1_000);
    detailElement.textContent = `${state.tabTitle} · ${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`;
    primaryButton.textContent = "録音を停止";
    primaryButton.classList.add("stop");
    if (timer === null) timer = window.setInterval(render, 1_000);
    return;
  }
  if (timer !== null) window.clearInterval(timer);
  timer = null;
  if (state.status === "starting" || state.status === "stopping") {
    statusElement.textContent = state.status === "starting" ? "開始しています…" : "停止しています…";
    detailElement.textContent = "";
    primaryButton.disabled = true;
    primaryButton.textContent = state.status === "starting" ? "開始" : "録音を停止";
    if (state.status === "stopping") primaryButton.classList.add("stop");
    return;
  }
  if (state.status === "error") {
    dotElement.classList.add("error");
    statusElement.textContent = "エラー";
    detailElement.textContent = state.message;
  } else if (serverReady) {
    dotElement.classList.add("ready");
    statusElement.textContent = "録音できます";
    detailElement.textContent = "現在のタブ音声だけを取得します。";
  } else {
    statusElement.textContent = "サーバーへ接続できません";
    detailElement.textContent = "先にローカルサーバーを起動してください。";
  }
  primaryButton.textContent = "開始";
  primaryButton.disabled = !serverReady;
}

async function send<T>(message: BackgroundMessage): Promise<T> {
  return chrome.runtime.sendMessage(message) as Promise<T>;
}

async function initialize(): Promise<void> {
  state = await send<RecordingState>({ type: "GET_STATE" });
  try {
    const [healthResponse, settingsResponse] = await Promise.all([
      fetch("http://127.0.0.1:8765/api/v1/health"),
      fetch("http://127.0.0.1:8765/api/v1/settings")
    ]);
    serverReady = healthResponse.ok;
    if (healthResponse.ok) await healthResponse.json();
    if (settingsResponse.ok) {
      const appSettings = (await settingsResponse.json()) as {
        transcription?: {
          language?: "ja" | "auto";
        };
      };
      language = appSettings.transcription?.language ?? "ja";
    }
  } catch {
    serverReady = false;
  }
  render();
}

primaryButton.addEventListener("click", async () => {
  primaryButton.disabled = true;
  if (state.status === "recording" || state.status === "reconnecting") {
    state = await send<RecordingState>({ type: "STOP_CAPTURE" });
  } else {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    if (!tab?.id) return;
    state = await send<RecordingState>({
      type: "START_CAPTURE",
      tabId: tab.id,
      tabTitle: tab.title ?? "無題の録音",
      tabUrl: tab.url,
      language
    });
  }
  render();
});

viewerButton.addEventListener("click", () => {
  const sessionId =
    state.status === "recording" || state.status === "reconnecting" ? state.sessionId : undefined;
  void send({ type: "OPEN_VIEWER", sessionId });
});

void initialize();
