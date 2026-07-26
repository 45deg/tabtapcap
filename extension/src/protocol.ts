export const AUDIO_MAGIC = [0x4c, 0x54, 0x43, 0x41] as const;
export const AUDIO_PROTOCOL_VERSION = 1;
export const AUDIO_HEADER_SIZE = 28;
export const FORMAT_PCM_S16LE = 1;

export interface AudioFrameInput {
  sequence: number;
  startSample: bigint;
  sampleRate: number;
  pcm: Int16Array;
  flags?: number;
}

export function encodeAudioFrame(input: AudioFrameInput): ArrayBuffer {
  const buffer = new ArrayBuffer(AUDIO_HEADER_SIZE + input.pcm.byteLength);
  const view = new DataView(buffer);
  AUDIO_MAGIC.forEach((byte, index) => view.setUint8(index, byte));
  view.setUint8(4, AUDIO_PROTOCOL_VERSION);
  view.setUint8(5, input.flags ?? 0);
  view.setUint16(6, AUDIO_HEADER_SIZE, true);
  view.setUint32(8, input.sequence, true);
  view.setBigUint64(12, input.startSample, true);
  view.setUint32(20, input.sampleRate, true);
  view.setUint8(24, 1);
  view.setUint8(25, FORMAT_PCM_S16LE);
  view.setUint16(26, 0, true);
  new Uint8Array(buffer, AUDIO_HEADER_SIZE).set(
    new Uint8Array(input.pcm.buffer, input.pcm.byteOffset, input.pcm.byteLength)
  );
  return buffer;
}

export type RecordingState =
  | { status: "idle" }
  | { status: "starting" }
  | {
      status: "recording" | "reconnecting";
      sessionId: string;
      startedAt: number;
      tabTitle: string;
    }
  | { status: "stopping"; sessionId: string }
  | { status: "error"; message: string };

export type BackgroundMessage =
  | { type: "GET_STATE" }
  | {
      type: "START_CAPTURE";
      tabId: number;
      tabTitle: string;
      tabUrl?: string;
      diarizationEnabled: boolean;
    }
  | { type: "STOP_CAPTURE" }
  | { type: "OPEN_VIEWER"; sessionId?: string }
  | { type: "CAPTURE_STATE"; state: RecordingState };
