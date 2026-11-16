// Only the Chrome host APIs and the test server address are substituted.
// AudioWorklet, framing, buffering, reconnect and stop logic are production code.
const parameters = new URLSearchParams(location.search);
const apiOrigin = parameters.get("api");
const repo = parameters.get("repo");
const originalWebSocket = window.WebSocket;
const originalFetch = window.fetch.bind(window);
const redirect = (url) => String(url).replace("127.0.0.1:8765", new URL(apiOrigin).host);
window.WebSocket = class extends originalWebSocket {
  constructor(url, protocols) { super(redirect(url), protocols); }
};
window.fetch = (url, init) => originalFetch(redirect(url), init);

let receiveMessage;
let source;
let stream;
window.captureHarness = {
  ready: false,
  levels: 0,
  states: [],
  sourceRate: 48_000,
  async start(title) {
    this.levels = 0;
    const response = await this.send({
      type: "START_CAPTURE", streamId: "synthetic-stream", tabTitle: title, language: "ja"
    });
    if (!response.ok) throw new Error(response.message);
    return response.state;
  },
  send(message) {
    return new Promise((resolve) => receiveMessage({ ...message, target: "offscreen" }, {}, resolve));
  },
  async stop() {
    const response = await this.send({ type: "STOP_CAPTURE" });
    if (source && source.state !== "closed") await source.close();
    return response;
  },
  async endTrack() {
    const track = stream.getAudioTracks()[0];
    track.stop();
    // MediaStreamTrack.stop() does not dispatch ended; emulate the browser's tab-close event.
    track.dispatchEvent(new Event("ended"));
    if (source && source.state !== "closed") await source.close();
  }
};

Object.defineProperty(navigator.mediaDevices, "getUserMedia", {
  value: async () => {
    source = new AudioContext({ sampleRate: 48_000 });
    const oscillator = source.createOscillator();
    oscillator.frequency.value = 440;
    const gain = source.createGain();
    gain.gain.value = 0.2;
    const destination = source.createMediaStreamDestination();
    oscillator.connect(gain).connect(destination);
    oscillator.start();
    await source.resume();
    stream = destination.stream;
    return stream;
  }
});
window.chrome = {
  runtime: {
    getURL: (path) => `/@fs${repo}/apps/extension/public/${path}`,
    onMessage: { addListener: (listener) => { receiveMessage = listener; } },
    sendMessage: async (message) => {
      if (message.type === "AUDIO_LEVEL_UPDATE") window.captureHarness.levels++;
      if (message.type === "CAPTURE_STATE") window.captureHarness.states.push(message.state);
      return { ok: true };
    }
  }
};

await import("../../apps/extension/src/offscreen.ts");
window.captureHarness.ready = true;
