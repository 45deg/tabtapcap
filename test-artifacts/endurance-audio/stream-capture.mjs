import { readFile } from "node:fs/promises";
import { performance } from "node:perf_hooks";

const [audioPath, portText = "8876"] = process.argv.slice(2);
if (!audioPath) {
  throw new Error("usage: node stream-capture.mjs <16-bit mono WAV> [port]");
}

const port = Number(portText);
const baseUrl = `http://127.0.0.1:${port}`;
const wav = await readFile(audioPath);

function readWave(buffer) {
  if (buffer.toString("ascii", 0, 4) !== "RIFF" || buffer.toString("ascii", 8, 12) !== "WAVE") {
    throw new Error("RIFF/WAVE ファイルではありません。");
  }

  let offset = 12;
  let format;
  let pcm;
  while (offset + 8 <= buffer.length) {
    const id = buffer.toString("ascii", offset, offset + 4);
    const size = buffer.readUInt32LE(offset + 4);
    const start = offset + 8;
    if (id === "fmt ") {
      format = {
        encoding: buffer.readUInt16LE(start),
        channels: buffer.readUInt16LE(start + 2),
        sampleRate: buffer.readUInt32LE(start + 4),
        bitsPerSample: buffer.readUInt16LE(start + 14)
      };
    } else if (id === "data") {
      pcm = buffer.subarray(start, start + size);
    }
    offset = start + size + (size % 2);
  }

  if (!format || !pcm) throw new Error("WAV の fmt/data チャンクが見つかりません。");
  if (format.encoding !== 1 || format.channels !== 1 || format.bitsPerSample !== 16) {
    throw new Error(`16-bit mono PCM が必要です: ${JSON.stringify(format)}`);
  }
  return { ...format, pcm };
}

function encodeFrame(sequence, startSample, sampleRate, payload) {
  const frame = Buffer.allocUnsafe(28 + payload.length);
  frame.write("LTCA", 0, "ascii");
  frame.writeUInt8(1, 4);
  frame.writeUInt8(0, 5);
  frame.writeUInt16LE(28, 6);
  frame.writeUInt32LE(sequence, 8);
  frame.writeBigUInt64LE(BigInt(startSample), 12);
  frame.writeUInt32LE(sampleRate, 20);
  frame.writeUInt8(1, 24);
  frame.writeUInt8(1, 25);
  frame.writeUInt16LE(0, 26);
  payload.copy(frame, 28);
  return frame;
}

function waitForMessage(socket, predicate) {
  return new Promise((resolve, reject) => {
    const onMessage = (event) => {
      const value = JSON.parse(String(event.data));
      if (value.type === "error") {
        cleanup();
        reject(new Error(value.message));
      } else if (predicate(value)) {
        cleanup();
        resolve(value);
      }
    };
    const onError = () => {
      cleanup();
      reject(new Error("WebSocket 接続でエラーが発生しました。"));
    };
    const cleanup = () => {
      socket.removeEventListener("message", onMessage);
      socket.removeEventListener("error", onError);
    };
    socket.addEventListener("message", onMessage);
    socket.addEventListener("error", onError);
  });
}

async function waitForOpen(socket) {
  if (socket.readyState === WebSocket.OPEN) return;
  await new Promise((resolve, reject) => {
    socket.addEventListener("open", resolve, { once: true });
    socket.addEventListener("error", reject, { once: true });
  });
}

const audio = readWave(wav);
const frameSamples = Math.round(audio.sampleRate / 10);
const frameBytes = frameSamples * 2;
const totalSamples = audio.pcm.length / 2;
const totalFrames = Math.ceil(audio.pcm.length / frameBytes);
const startedAt = performance.now();
const socket = new WebSocket(`ws://127.0.0.1:${port}/ws/v1/capture`);
await waitForOpen(socket);

const startedMessage = waitForMessage(socket, (message) => message.type === "started");
socket.send(
  JSON.stringify({
    type: "start",
    sampleRate: audio.sampleRate,
    language: "ja",
    tabTitle: "say 30分耐久テスト",
    tabUrl: "local://say-endurance-30m"
  })
);
const { sessionId } = await startedMessage;

let sent = 0;
let acknowledged = 0;
let nextOffset = 0;
const maxInFlight = 256;
const allAcknowledged = new Promise((resolve, reject) => {
  socket.addEventListener("message", (event) => {
    const message = JSON.parse(String(event.data));
    if (message.type === "error") reject(new Error(message.message));
    if (message.type !== "ack") return;
    acknowledged += 1;
    if (acknowledged === totalFrames) resolve();
    else pump();
  });

  function pump() {
    while (sent < totalFrames && sent - acknowledged < maxInFlight) {
      const payload = audio.pcm.subarray(nextOffset, Math.min(nextOffset + frameBytes, audio.pcm.length));
      socket.send(encodeFrame(sent, nextOffset / 2, audio.sampleRate, payload));
      sent += 1;
      nextOffset += payload.length;
    }
  }

  pump();
});

await allAcknowledged;
const captureFinishedAt = performance.now();
const stoppedMessage = waitForMessage(socket, (message) => message.type === "stopped");
socket.send(JSON.stringify({ type: "stop", sessionId }));
await stoppedMessage;
socket.close();

let session;
for (;;) {
  const response = await fetch(`${baseUrl}/api/v1/sessions/${sessionId}`);
  if (!response.ok) throw new Error(`セッション取得に失敗しました: HTTP ${response.status}`);
  session = await response.json();
  if (session.state === "ready" || session.state === "error") break;
  await new Promise((resolve) => setTimeout(resolve, 1_000));
}
const completedAt = performance.now();

const report = {
  sessionId,
  state: session.state,
  errorCode: session.error_code,
  errorMessage: session.error_message,
  source: {
    path: audioPath,
    sampleRate: audio.sampleRate,
    channels: audio.channels,
    bitsPerSample: audio.bitsPerSample,
    totalSamples,
    durationSeconds: totalSamples / audio.sampleRate,
    bytes: audio.pcm.length,
    frames: totalFrames
  },
  capture: {
    sentFrames: sent,
    acknowledgedFrames: acknowledged,
    elapsedSeconds: (captureFinishedAt - startedAt) / 1_000,
    realtimeMultiple: totalSamples / audio.sampleRate / ((captureFinishedAt - startedAt) / 1_000)
  },
  processing: {
    elapsedSeconds: (completedAt - captureFinishedAt) / 1_000
  },
  result: {
    durationMs: session.duration_ms,
    totalSamples: session.total_samples,
    audioGap: session.audio_gap,
    utteranceCount: session.utterances.length,
    characterCount: session.utterances.reduce(
      (sum, utterance) => sum + (utterance.edited_text ?? utterance.raw_text).length,
      0
    ),
    firstUtterance: session.utterances.at(0)?.raw_text ?? null,
    lastUtterance: session.utterances.at(-1)?.raw_text ?? null
  }
};

console.log(JSON.stringify(report, null, 2));
if (session.state !== "ready") process.exitCode = 1;
