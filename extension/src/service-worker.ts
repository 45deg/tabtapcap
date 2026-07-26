import type { BackgroundMessage, RecordingState } from "./protocol";

const OFFSCREEN_URL = "src/offscreen.html";
const VIEWER_URL = import.meta.env.VITE_VIEWER_URL ?? "http://127.0.0.1:8765";
let state: RecordingState = { status: "idle" };
let creatingOffscreen: Promise<void> | null = null;
const stateReady = restoreState();

async function restoreState(): Promise<void> {
  const stored = await chrome.storage.session.get("recordingState");
  if (stored.recordingState) state = stored.recordingState as RecordingState;
}

async function ensureOffscreenDocument(): Promise<void> {
  const offscreenUrl = chrome.runtime.getURL(OFFSCREEN_URL);
  const contexts = await chrome.runtime.getContexts({
    contextTypes: [chrome.runtime.ContextType.OFFSCREEN_DOCUMENT],
    documentUrls: [offscreenUrl]
  });
  if (contexts.length > 0) return;
  if (!creatingOffscreen) {
    creatingOffscreen = chrome.offscreen
      .createDocument({
        url: OFFSCREEN_URL,
        reasons: [chrome.offscreen.Reason.USER_MEDIA],
        justification: "Capture the selected tab audio for local transcription"
      })
      .finally(() => {
        creatingOffscreen = null;
      });
  }
  await creatingOffscreen;
}

async function setState(next: RecordingState): Promise<void> {
  state = next;
  await chrome.storage.session.set({ recordingState: next });
  const badge =
    next.status === "recording"
      ? "REC"
      : next.status === "reconnecting"
        ? "…"
        : next.status === "error"
          ? "!"
          : "";
  await chrome.action.setBadgeText({ text: badge });
  await chrome.action.setBadgeBackgroundColor({
    color: next.status === "error" ? "#b42318" : next.status === "reconnecting" ? "#8a6116" : "#c43131"
  });
}

chrome.runtime.onMessage.addListener(
  (message: BackgroundMessage, _sender, sendResponse) => {
    void (async () => {
      await stateReady;
      if (message.type === "GET_STATE") {
        sendResponse(state);
        return;
      }
      if (message.type === "START_CAPTURE") {
        if (state.status !== "idle" && state.status !== "error") {
          throw new Error("別の録音が進行中です。");
        }
        await setState({ status: "starting" });
        await ensureOffscreenDocument();
        const streamId = await chrome.tabCapture.getMediaStreamId({
          targetTabId: message.tabId
        });
        const response = await chrome.runtime.sendMessage({
          target: "offscreen",
          type: "START_CAPTURE",
          streamId,
          tabTitle: message.tabTitle,
          tabUrl: message.tabUrl,
          language: message.language
        });
        if (!response?.ok) throw new Error(response?.message ?? "録音を開始できませんでした。");
        await setState(response.state as RecordingState);
        sendResponse(response.state);
        return;
      }
      if (message.type === "STOP_CAPTURE") {
        if (state.status !== "recording" && state.status !== "reconnecting") {
          sendResponse(state);
          return;
        }
        await setState({ status: "stopping", sessionId: state.sessionId });
        const response = await chrome.runtime.sendMessage({
          target: "offscreen",
          type: "STOP_CAPTURE"
        });
        if (!response?.ok) throw new Error(response?.message ?? "録音を停止できませんでした。");
        await setState({ status: "idle" });
        sendResponse({ status: "idle" });
        return;
      }
      if (message.type === "CAPTURE_STATE") {
        await setState(message.state);
        sendResponse({ ok: true });
        return;
      }
      if (message.type === "OPEN_VIEWER") {
        const suffix = message.sessionId ? `/?session=${message.sessionId}` : "/";
        await chrome.tabs.create({ url: `${VIEWER_URL}${suffix}` });
        sendResponse({ ok: true });
      }
    })().catch(async (error: unknown) => {
      const message = error instanceof Error ? error.message : String(error);
      await setState({ status: "error", message });
      sendResponse({ ok: false, message });
    });
    return true;
  }
);
