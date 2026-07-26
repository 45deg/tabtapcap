import { encodeAudioFrame, pcmVolumeLevel, type RecordingState } from "./protocol";

const SERVER_WS = "ws://127.0.0.1:8765/ws/v1/capture";
const MAX_PENDING_BYTES = 12 * 1024 * 1024;

let stream: MediaStream | null = null;
let audioContext: AudioContext | null = null;
let socket: WebSocket | null = null;
let worklet: AudioWorkletNode | null = null;
let sequence = 0;
let startSample = 0n;
let pending = new Map<number, ArrayBuffer>();
let pendingBytes = 0;
let activeSessionId: string | null = null;
let startedAt = 0;
let tabTitle = "";
let reconnectTimer: number | null = null;
let disconnectedAt: number | null = null;
let stopping = false;

function openSocket(): Promise<WebSocket> {
  return new Promise((resolve, reject) => {
    const candidate = new WebSocket(SERVER_WS);
    candidate.binaryType = "arraybuffer";
    candidate.addEventListener("open", () => resolve(candidate), { once: true });
    candidate.addEventListener("error", () => reject(new Error("ローカルサーバーへ接続できません。")), {
      once: true
    });
  });
}

function waitForMessage<T extends { type: string }>(
  target: WebSocket,
  expectedType: string
): Promise<T> {
  return new Promise((resolve, reject) => {
    const timer = window.setTimeout(() => {
      cleanup();
      reject(new Error("サーバーからの応答がタイムアウトしました。"));
    }, 10_000);
    const onMessage = (event: MessageEvent<string>) => {
      const payload = JSON.parse(event.data) as T;
      if (payload.type !== expectedType) return;
      cleanup();
      resolve(payload);
    };
    const cleanup = () => {
      window.clearTimeout(timer);
      target.removeEventListener("message", onMessage);
    };
    target.addEventListener("message", onMessage);
  });
}

function attachSocketHandlers(target: WebSocket): void {
  target.addEventListener("message", (event: MessageEvent<string>) => {
    const payload = JSON.parse(event.data) as { type: string; sequence?: number; message?: string };
    if (payload.type === "ack" && payload.sequence !== undefined) {
      for (const [key, frame] of pending) {
        if (key <= payload.sequence) {
          pendingBytes -= frame.byteLength;
          pending.delete(key);
        }
      }
    }
    if (payload.type === "error") void fail(payload.message ?? "録音サーバーでエラーが発生しました。");
  });
  target.addEventListener("close", () => {
    if (!stopping && stream?.active) {
      disconnectedAt ??= Date.now();
      void scheduleReconnect();
    }
  });
}

async function notifyState(state: RecordingState): Promise<void> {
  await chrome.runtime.sendMessage({ type: "CAPTURE_STATE", state });
}

async function scheduleReconnect(): Promise<void> {
  if (reconnectTimer !== null || !activeSessionId) return;
  if (disconnectedAt !== null && Date.now() - disconnectedAt > 60_000) {
    await fail("サーバーへ60秒間再接続できなかったため、録音を停止しました。");
    return;
  }
  await notifyState({
    status: "reconnecting",
    sessionId: activeSessionId,
    startedAt,
    tabTitle
  });
  reconnectTimer = window.setTimeout(async () => {
    reconnectTimer = null;
    try {
      const next = await openSocket();
      const resumedPromise = waitForMessage<{
        type: "resumed";
        sessionId: string;
        expectedSequence: number;
      }>(next, "resumed");
      next.send(JSON.stringify({ type: "resume", sessionId: activeSessionId }));
      const resumed = await resumedPromise;
      attachSocketHandlers(next);
      socket = next;
      for (const [frameSequence, frame] of pending) {
        if (frameSequence >= resumed.expectedSequence) next.send(frame);
      }
      disconnectedAt = null;
      await notifyState({
        status: "recording",
        sessionId: activeSessionId!,
        startedAt,
        tabTitle
      });
    } catch {
      await scheduleReconnect();
    }
  }, 2_000);
}

async function startCapture(message: {
  streamId: string;
  tabTitle: string;
  tabUrl?: string;
  language: "ja" | "auto";
}): Promise<RecordingState> {
  if (stream) throw new Error("既に録音中です。");
  stopping = false;
  tabTitle = message.tabTitle;
  stream = await navigator.mediaDevices.getUserMedia({
    audio: {
      // Chromium-specific constraints required for tabCapture stream IDs.
      mandatory: {
        chromeMediaSource: "tab",
        chromeMediaSourceId: message.streamId
      }
    } as MediaTrackConstraints,
    video: false
  });
  audioContext = new AudioContext();
  await audioContext.audioWorklet.addModule(chrome.runtime.getURL("audio-worklet.js"));
  const source = audioContext.createMediaStreamSource(stream);
  source.connect(audioContext.destination);
  worklet = new AudioWorkletNode(audioContext, "pcm-capture");
  const silentGain = audioContext.createGain();
  silentGain.gain.value = 0;
  source.connect(worklet).connect(silentGain).connect(audioContext.destination);

  socket = await openSocket();
  const startedPromise = waitForMessage<{ type: "started"; sessionId: string }>(socket, "started");
  socket.send(
    JSON.stringify({
      type: "start",
      sampleRate: audioContext.sampleRate,
      channels: 1,
      format: "s16le",
      language: message.language,
      tabTitle: message.tabTitle,
      tabUrl: message.tabUrl
    })
  );
  const started = await startedPromise;
  activeSessionId = started.sessionId;
  startedAt = Date.now();
  attachSocketHandlers(socket);

  worklet.port.onmessage = (event: MessageEvent<Int16Array>) => {
    const pcm = event.data;
    void chrome.runtime.sendMessage({
      type: "AUDIO_LEVEL_UPDATE",
      sessionId: activeSessionId!,
      level: pcmVolumeLevel(pcm)
    });
    const frame = encodeAudioFrame({
      sequence,
      startSample,
      sampleRate: audioContext!.sampleRate,
      pcm
    });
    pending.set(sequence, frame);
    pendingBytes += frame.byteLength;
    if (socket?.readyState === WebSocket.OPEN) socket.send(frame);
    sequence += 1;
    startSample += BigInt(pcm.length);
    if (pendingBytes > MAX_PENDING_BYTES) {
      void fail("未送信音声が60秒を超えたため、録音を安全に停止しました。");
    }
  };
  stream.getAudioTracks()[0]?.addEventListener("ended", () => void stopCapture());
  return {
    status: "recording",
    sessionId: activeSessionId,
    startedAt,
    tabTitle
  };
}

async function stopCapture(): Promise<void> {
  if (stopping) return;
  stopping = true;
  if (reconnectTimer !== null) window.clearTimeout(reconnectTimer);
  reconnectTimer = null;
  disconnectedAt = null;
  if (socket?.readyState === WebSocket.OPEN) {
    const stopped = waitForMessage(socket, "stopped");
    socket.send(JSON.stringify({ type: "stop", sessionId: activeSessionId, finalSample: startSample.toString() }));
    await stopped.catch(() => undefined);
  }
  stream?.getTracks().forEach((track) => track.stop());
  worklet?.disconnect();
  await audioContext?.close();
  socket?.close();
  stream = null;
  worklet = null;
  audioContext = null;
  socket = null;
  activeSessionId = null;
  sequence = 0;
  startSample = 0n;
  pending.clear();
  pendingBytes = 0;
  stopping = false;
}

async function fail(message: string): Promise<void> {
  await stopCapture();
  await notifyState({ status: "error", message });
}

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message.target !== "offscreen") return;
  void (async () => {
    if (message.type === "START_CAPTURE") {
      try {
        const state = await startCapture(message);
        sendResponse({ ok: true, state });
      } catch (error) {
        await stopCapture();
        throw error;
      }
    } else if (message.type === "STOP_CAPTURE") {
      await stopCapture();
      sendResponse({ ok: true });
    }
  })().catch((error: unknown) => {
    sendResponse({
      ok: false,
      message: error instanceof Error ? error.message : String(error)
    });
  });
  return true;
});
