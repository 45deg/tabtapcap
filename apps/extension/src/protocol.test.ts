import { describe, expect, it } from "vitest";
import { AUDIO_HEADER_SIZE, encodeAudioFrame, pcmVolumeLevel } from "./protocol";

describe("encodeAudioFrame", () => {
  it("encodes the fixed binary header and PCM payload", () => {
    const pcm = new Int16Array([0, 1, -1, 32767, -32768]);
    const buffer = encodeAudioFrame({
      sequence: 42,
      startSample: 96_000n,
      sampleRate: 48_000,
      pcm
    });
    const view = new DataView(buffer);
    expect(buffer.byteLength).toBe(AUDIO_HEADER_SIZE + pcm.byteLength);
    expect(new TextDecoder().decode(new Uint8Array(buffer, 0, 4))).toBe("LTCA");
    expect(view.getUint32(8, true)).toBe(42);
    expect(view.getBigUint64(12, true)).toBe(96_000n);
    expect(view.getUint32(20, true)).toBe(48_000);
  });

  it("derives a perceptual volume level from PCM samples", () => {
    expect(pcmVolumeLevel(new Int16Array([0, 0]))).toBe(0);
    expect(pcmVolumeLevel(new Int16Array([32767, -32768]))).toBeCloseTo(1);
  });
});
