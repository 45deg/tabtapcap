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
let stopPromise: Promise<void> | null = null;
let reconnectPromise: Promise<WebSocket> | null = null;

function openSocket(): Promise<WebSocket> {
  return new Promise((resolve, reject) => {
    const candidate = new WebSocket(SERVER_WS);
    candidate.binaryType = "arraybuffer";
    const cleanup = () => {
      window.clearTimeout(timer);
      candidate.removeEventListener("open", onOpen);
      candidate.removeEventListener("error", onError);
      candidate.removeEventListener("close", onError);
    };
    const onOpen = () => { cleanup(); resolve(candidate); };
    const onError = () => {
      cleanup();
      candidate.close();
      reject(new Error("ローカルサーバーへ接続できません。"));
    };
    const timer = window.setTimeout(onError, 10_000);
    candidate.addEventListener("open", onOpen);
    candidate.addEventListener("error", onError);
    candidate.addEventListener("close", onError);
  });
}

function waitForMessage<T extends { type: string }>(
  target: WebSocket,
  expectedType: string,
  accept: (payload: T) => boolean = () => true
): Promise<T> {
  return new Promise((resolve, reject) => {
    const timer = window.setTimeout(() => {
      cleanup();
      reject(new Error("サーバーからの応答がタイムアウトしました。"));
    }, 10_000);
    const onMessage = (event: MessageEvent<string>) => {
      const payload = JSON.parse(event.data) as T & { message?: string };
      if (payload.type === "error") {
        cleanup();
        reject(new Error(payload.message ?? "録音サーバーでエラーが発生しました。"));
        return;
      }
      if (payload.type !== expectedType || !accept(payload)) return;
      cleanup();
      resolve(payload);
    };
    const cleanup = () => {
      window.clearTimeout(timer);
      target.removeEventListener("message", onMessage);
      target.removeEventListener("close", onClose);
    };
    const onClose = () => {
      cleanup();
      reject(new Error("録音サーバーとの接続が切れました。"));
    };
    target.addEventListener("message", onMessage);
    target.addEventListener("close", onClose);
  });
}

function attachSocketHandlers(target: WebSocket): void {
  target.addEventListener("message", (event: MessageEvent<string>) => {
    const payload = JSON.parse(event.data) as { type: string; sequence?: number; message?: string };
    if (payload.type === "ack" && payload.sequence !== undefined) {
      acknowledgeThrough(payload.sequence);
    }
    if (payload.type === "error" && !stopping) void fail(payload.message ?? "録音サーバーでエラーが発生しました。");
  });
  target.addEventListener("close", () => {
    if (target === socket && !stopping && stream?.active) {
      disconnectedAt ??= Date.now();
      void scheduleReconnect();
    }
  });
}

async function notifyState(state: RecordingState): Promise<void> {
  await chrome.runtime.sendMessage({ type: "CAPTURE_STATE", state });
}

function acknowledgeThrough(sequence: number): void {
  for (const [key, frame] of pending) {
    if (key <= sequence) {
      pendingBytes -= frame.byteLength;
      pending.delete(key);
    }
  }
}

function resumeCapture(): Promise<WebSocket> {
  if (reconnectPromise) return reconnectPromise;
  const sessionId = activeSessionId;
  reconnectPromise = (async () => {
    const next = await openSocket();
    try {
      const resumedPromise = waitForMessage<{ type: "resumed"; expectedSequence: number }>(next, "resumed");
      next.send(JSON.stringify({ type: "resume", sessionId }));
      const resumed = await resumedPromise;
      if (sessionId !== activeSessionId) throw new Error("録音セッションが変わりました。");
      // An ACK may have been lost even though the server already wrote the frame.
      acknowledgeThrough(resumed.expectedSequence - 1);
      socket = next;
      attachSocketHandlers(next);
      for (const frame of pending.values()) next.send(frame);
      disconnectedAt = null;
      return next;
    } catch (error) {
      next.close();
      throw error;
    }
  })().finally(() => { reconnectPromise = null; });
  return reconnectPromise;
}

async function scheduleReconnect(): Promise<void> {
  if (stopping || reconnectTimer !== null || reconnectPromise || !activeSessionId) return;
  if (disconnectedAt !== null && Date.now() - disconnectedAt > 60_000) {
    await fail("サーバーへ60秒間再接続できなかったため、録音を停止しました。");
    return;
  }
  reconnectTimer = window.setTimeout(async () => {
    reconnectTimer = null;
    if (stopping || !activeSessionId) return;
    try {
      await resumeCapture();
      if (stopping || !activeSessionId) return;
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
  await notifyState({ status: "reconnecting", sessionId: activeSessionId, startedAt, tabTitle });
}

async function startCapture(message: {
  streamId: string;
  tabTitle: string;
  tabUrl?: string;
  language: "ja" | "auto";
}): Promise<RecordingState> {
  if (stream || activeSessionId) throw new Error("前の録音の停止を完了してください。");
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
    if (stopping) return;
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
  stream.getAudioTracks()[0]?.addEventListener("ended", () => {
    void stopCapture().catch(() => { /* stopCapture reports the recoverable error. */ });
  });
  return {
    status: "recording",
    sessionId: activeSessionId,
    startedAt,
    tabTitle
  };
}

function stopCapture(): Promise<void> {
  if (stopPromise) return stopPromise;
  stopPromise = finishCapture().finally(() => { stopPromise = null; });
  return stopPromise;
}

async function releaseMedia(): Promise<void> {
  if (worklet) worklet.port.onmessage = null;
  stream?.getTracks().forEach((track) => track.stop());
  worklet?.disconnect();
  await audioContext?.close();
  stream = null;
  worklet = null;
  audioContext = null;
}

function clearCapture(): void {
  socket?.close();
  socket = null;
  activeSessionId = null;
  sequence = 0;
  startSample = 0n;
  pending.clear();
  pendingBytes = 0;
}

async function captureWasFinalized(): Promise<boolean> {
  if (!activeSessionId) return false;
  const controller = new AbortController();
  const timer = window.setTimeout(() => controller.abort(), 5_000);
  try {
    const response = await fetch(`http://127.0.0.1:8765/api/v1/sessions/${activeSessionId}`, {
      signal: controller.signal
    });
    if (!response.ok) return false;
    const session = await response.json() as { id: string; state: string; total_samples: number };
    return session.id === activeSessionId &&
      ["finalizing", "transcribing", "formatting", "ready", "error", "interrupted"].includes(session.state) &&
      Number.isSafeInteger(session.total_samples) && BigInt(session.total_samples) >= startSample;
  } catch {
    return false;
  } finally {
    window.clearTimeout(timer);
  }
}

async function finishCapture(): Promise<void> {
  stopping = true;
  if (reconnectTimer !== null) window.clearTimeout(reconnectTimer);
  reconnectTimer = null;
  disconnectedAt = null;
  try {
    await releaseMedia();
    if (activeSessionId) {
      await notifyState({ status: "stopping", sessionId: activeSessionId });
      const target = socket?.readyState === WebSocket.OPEN ? socket : await resumeCapture();
      if (pending.size > 0) {
        await waitForMessage(target, "ack", () => pending.size === 0);
      }
      const stopped = waitForMessage(target, "stopped");
      target.send(JSON.stringify({ type: "stop", sessionId: activeSessionId, finalSample: startSample.toString() }));
      await stopped;
    }
    clearCapture();
    await notifyState({ status: "idle" });
  } catch (reason) {
    // The server can commit the stop just before the WebSocket disconnects.
    if (await captureWasFinalized()) {
      clearCapture();
      await notifyState({ status: "idle" });
      return;
    }
    const message = `${reason instanceof Error ? reason.message : String(reason)} 未送信音声を保持しています。停止を再試行してください。`;
    socket?.close();
    socket = null;
    await notifyState({ status: "error", message, sessionId: activeSessionId ?? undefined });
    throw new Error(message);
  } finally {
    stopping = false;
  }
}

async function fail(message: string): Promise<void> {
  try {
    await stopCapture();
    await notifyState({ status: "error", message });
  } catch {
    // Preserve the session ID and pending audio reported by finishCapture.
  }
}

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message.target !== "offscreen") return;
  void (async () => {
    if (message.type === "START_CAPTURE") {
      try {
        const state = await startCapture(message);
        sendResponse({ ok: true, state });
      } catch (error) {
        if (!activeSessionId) {
          await releaseMedia();
          socket?.close();
          socket = null;
        }
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
