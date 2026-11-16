import { afterEach, beforeEach, expect, it, vi } from "vitest";

type Reply = { ok: boolean; message?: string };
type Listener = (message: unknown, sender: unknown, reply: (value: Reply) => void) => void;
let listener: Listener;
let online: boolean;
let acknowledge: boolean;
let loseStopReply: boolean;
let expectedSequence: number;
let received: number[];
let notifications: { type: string; state?: { status: string } }[];
let track: EventTarget & { stop: ReturnType<typeof vi.fn> };

class FakeSocket extends EventTarget {
  static OPEN = 1;
  static CLOSED = 3;
  static instances: FakeSocket[] = [];
  readyState = 0;
  binaryType = "";
  sent: (string | ArrayBuffer)[] = [];
  constructor(_url: string) {
    super();
    FakeSocket.instances.push(this);
    queueMicrotask(() => {
      if (online) {
        this.readyState = FakeSocket.OPEN;
        this.dispatchEvent(new Event("open"));
      } else {
        this.dispatchEvent(new Event("error"));
        this.close();
      }
    });
  }
  message(payload: object) {
    this.dispatchEvent(new MessageEvent("message", { data: JSON.stringify(payload) }));
  }
  send(data: string | ArrayBuffer) {
    if (this.readyState !== FakeSocket.OPEN) throw new Error("closed socket");
    this.sent.push(data);
    if (typeof data !== "string") {
      const view = new DataView(data);
      const sequence = view.getUint32(8, true);
      if (sequence === expectedSequence) {
        received.push(...new Int16Array(data, 28));
        expectedSequence++;
      }
      if (acknowledge) queueMicrotask(() => this.message({ type: "ack", sequence }));
      return;
    }
    const command = JSON.parse(data) as { type: string };
    queueMicrotask(() => {
      if (command.type === "start") this.message({ type: "started", sessionId: "session-1" });
      if (command.type === "resume") this.message({ type: "resumed", sessionId: "session-1", expectedSequence });
      if (command.type === "stop") {
        if (loseStopReply) this.close();
        else this.message({ type: "stopped", sessionId: "session-1" });
      }
    });
  }
  close() {
    if (this.readyState === FakeSocket.CLOSED) return;
    this.readyState = FakeSocket.CLOSED;
    this.dispatchEvent(new Event("close"));
  }
}

class FakeWorklet {
  static current: FakeWorklet;
  port = { onmessage: null as ((event: { data: Int16Array }) => void) | null };
  constructor() { FakeWorklet.current = this; }
  connect(node: unknown) { return node; }
  disconnect() {}
}

function send(type: string): Promise<Reply> {
  return new Promise((resolve) => listener({ target: "offscreen", type, streamId: "stream-1", tabTitle: "Tab", language: "ja" }, {}, resolve));
}
function capture(...samples: number[]) {
  FakeWorklet.current.port.onmessage?.({ data: new Int16Array(samples) });
}

beforeEach(async () => {
  vi.resetModules();
  vi.useFakeTimers();
  online = true;
  acknowledge = true;
  loseStopReply = false;
  expectedSequence = 0;
  received = [];
  notifications = [];
  FakeSocket.instances = [];
  track = Object.assign(new EventTarget(), { stop: vi.fn() });
  vi.stubGlobal("window", globalThis);
  vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new Error("Offline")));
  vi.stubGlobal("WebSocket", FakeSocket);
  vi.stubGlobal("AudioWorkletNode", FakeWorklet);
  vi.stubGlobal("AudioContext", class {
    sampleRate = 48000;
    destination = {};
    audioWorklet = { addModule: vi.fn().mockResolvedValue(undefined) };
    createMediaStreamSource() { return { connect: (node: unknown) => node }; }
    createGain() { return { gain: { value: 1 }, connect: (node: unknown) => node }; }
    async close() {}
  });
  vi.stubGlobal("navigator", { mediaDevices: { getUserMedia: async () => ({ active: true, getTracks: () => [track], getAudioTracks: () => [track] }) } });
  vi.stubGlobal("chrome", { runtime: {
    getURL: (path: string) => path,
    sendMessage: async (message: typeof notifications[number]) => { notifications.push(message); },
    onMessage: { addListener: (next: Listener) => { listener = next; } }
  } });
  await import("./offscreen");
  expect((await send("START_CAPTURE")).ok).toBe(true);
});

afterEach(() => {
  vi.clearAllTimers();
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

it("resumes and delivers buffered audio before stopping a disconnected capture", async () => {
  capture(11, 12);
  await Promise.resolve();
  FakeSocket.instances[0]!.close();
  capture(21, 22);
  capture(31, 32);
  const reply = await send("STOP_CAPTURE");
  expect(reply.ok).toBe(true);
  expect(received).toEqual([11, 12, 21, 22, 31, 32]);
  const resumed = FakeSocket.instances[1]!;
  expect(JSON.parse(resumed.sent[0] as string).type).toBe("resume");
  expect(JSON.parse(resumed.sent.at(-1) as string).type).toBe("stop");
});

it("reconciles a lost ACK without duplicating audio on resume", async () => {
  acknowledge = false;
  capture(11, 12);
  FakeSocket.instances[0]!.close();
  capture(21, 22);
  acknowledge = true;
  expect((await send("STOP_CAPTURE")).ok).toBe(true);
  expect(received).toEqual([11, 12, 21, 22]);
});

it("reports a failed stop and keeps buffered audio available for retry", async () => {
  FakeSocket.instances[0]!.close();
  capture(41, 42);
  online = false;
  expect((await send("STOP_CAPTURE")).ok).toBe(false);
  expect(track.stop).toHaveBeenCalled();
  expect(notifications.some((item) => item.state?.status === "idle")).toBe(false);
  online = true;
  expect((await send("STOP_CAPTURE")).ok).toBe(true);
  expect(received).toEqual([41, 42]);
});

it("notifies idle when the captured tab ends and permits a new capture", async () => {
  track.dispatchEvent(new Event("ended"));
  await vi.advanceTimersByTimeAsync(0);
  expect(notifications).toContainEqual({ type: "CAPTURE_STATE", state: { status: "idle" } });
  expect((await send("START_CAPTURE")).ok).toBe(true);
});

it("checks server state if the stop succeeded but its reply was lost", async () => {
  capture(51, 52);
  await Promise.resolve();
  loseStopReply = true;
  vi.mocked(fetch).mockResolvedValue(new Response(JSON.stringify({
    id: "session-1", state: "finalizing", total_samples: 2
  })));
  expect((await send("STOP_CAPTURE")).ok).toBe(true);
  expect(notifications).toContainEqual({ type: "CAPTURE_STATE", state: { status: "idle" } });
});

it("does not accept a finalized recording that is missing buffered samples", async () => {
  FakeSocket.instances[0]!.close();
  capture(61, 62);
  online = false;
  vi.mocked(fetch).mockResolvedValue(new Response(JSON.stringify({
    id: "session-1", state: "finalizing", total_samples: 0
  })));
  expect((await send("STOP_CAPTURE")).ok).toBe(false);
  expect(notifications.some((item) => item.state?.status === "idle")).toBe(false);
});
