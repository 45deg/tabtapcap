import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import App from "./App";
import { api } from "./api";
import type { SessionDetail } from "./types";

vi.mock("./api", () => ({
  api: { health: vi.fn(), sessions: vi.fn(), session: vi.fn(), updateUtterance: vi.fn() },
  serverWebSocketUrl: (path: string) => `ws://localhost${path}`,
  serverUrl: (path: string) => path,
  saveExportFile: vi.fn()
}));

function recording(id: string): SessionDetail {
  return {
    id, title: `Recording ${id}`, state: "ready", language: "ja",
    diarization_enabled: false, total_samples: 0, sample_rate: 16000,
    revision: 1, progress: 1, audio_gap: false, created_at: "2026-09-08T00:00:00Z",
    stopped_at: null, error_code: null, error_message: null, duration_ms: 2000,
    tab_url: null, speakers: [], utterances: [0, 1].map((n) => ({
      id: `${id}-${n}`, speaker_id: "s1", position: n, start_ms: n * 1000,
      end_ms: (n + 1) * 1000, raw_text: `Original ${n}`, edited_text: null,
      paragraph_break_before: false, confidence: null
    }))
  };
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => { resolve = done; });
  return { promise, resolve };
}

class FakeSocket {
  static instances: FakeSocket[] = [];
  onmessage: ((event: { data: string }) => void) | null = null;
  onopen: (() => void) | null = null;
  onclose: (() => void) | null = null;
  constructor(public url: string) { FakeSocket.instances.push(this); }
  close = vi.fn();
}

beforeEach(() => {
  FakeSocket.instances = [];
  vi.stubGlobal("WebSocket", FakeSocket);
  vi.mocked(api.health).mockResolvedValue({ status: "ok", version: "1", models: { transcription: true }, active_session_id: null });
  vi.mocked(api.sessions).mockResolvedValue([recording("A"), recording("B")]);
  vi.mocked(api.session).mockImplementation(async (id) => recording(id));
});

afterEach(() => {
  cleanup();
  vi.useRealTimers();
  vi.unstubAllGlobals();
  vi.resetAllMocks();
  history.replaceState(null, "", "/");
});

it("preserves other unsaved text and paragraph edits when saving one utterance", async () => {
  vi.mocked(api.updateUtterance).mockImplementation(async (_session, id, text) => {
    const response = recording("A");
    response.revision++;
    response.utterances.find((item) => item.id === id)!.edited_text = text;
    return response;
  });
  render(<App />);
  await screen.findByLabelText("0:00の発話");
  fireEvent.change(screen.getByLabelText("0:00の発話"), { target: { value: "Saved edit" } });
  fireEvent.change(screen.getByLabelText("0:01の発話"), { target: { value: "Unsaved draft" } });
  fireEvent.click(screen.getAllByRole("checkbox")[1]);
  await act(async () => {
    fireEvent.click(screen.getAllByRole("button", { name: "変更を保存" })[0]);
  });
  expect(screen.getByLabelText("0:01の発話")).toHaveValue("Unsaved draft");
  expect(screen.getAllByRole("checkbox")[1]).toBeChecked();
  expect(screen.getAllByRole("button", { name: "変更を保存" })).toHaveLength(1);
});

it("ignores an older response after selecting another recording", async () => {
  const delayed = deferred<SessionDetail>();
  vi.mocked(api.session).mockImplementation((id) => id === "A" ? delayed.promise : Promise.resolve(recording(id)));
  render(<App />);
  await waitFor(() => expect(api.session).toHaveBeenCalledWith("A"));
  fireEvent.click(screen.getByRole("button", { name: /Recording B/ }));
  await waitFor(() => expect(screen.getByLabelText("録音タイトル")).toHaveValue("Recording B"));
  await act(async () => { delayed.resolve(recording("A")); });
  expect(screen.getByLabelText("録音タイトル")).toHaveValue("Recording B");
});

it("keeps text typed while a save is in flight", async () => {
  const delayed = deferred<SessionDetail>();
  vi.mocked(api.updateUtterance).mockReturnValue(delayed.promise);
  render(<App />);
  const input = await screen.findByLabelText("0:00の発話");
  fireEvent.change(input, { target: { value: "Submitted" } });
  fireEvent.click(screen.getByRole("button", { name: "変更を保存" }));
  fireEvent.change(input, { target: { value: "Still typing" } });
  const response = recording("A");
  response.revision++;
  response.utterances[0].edited_text = "Submitted";
  await act(async () => { delayed.resolve(response); });
  expect(input).toHaveValue("Still typing");
  expect(screen.getByRole("button", { name: "変更を保存" })).toBeEnabled();
});

it("hides the previous recording's actions while the next recording loads", async () => {
  const delayed = deferred<SessionDetail>();
  vi.mocked(api.session).mockImplementation((id) => id === "B" ? delayed.promise : Promise.resolve(recording(id)));
  render(<App />);
  await screen.findByLabelText("録音タイトル");
  fireEvent.click(screen.getByRole("button", { name: /Recording B/ }));
  expect(screen.queryByRole("button", { name: "削除" })).not.toBeInTheDocument();
  await act(async () => { delayed.resolve(recording("B")); });
});

it("does not replace the selected recording with a late save response", async () => {
  const delayed = deferred<SessionDetail>();
  vi.mocked(api.updateUtterance).mockReturnValue(delayed.promise);
  render(<App />);
  await screen.findByLabelText("0:00の発話");
  fireEvent.change(screen.getByLabelText("0:00の発話"), { target: { value: "Edit A" } });
  fireEvent.click(screen.getByRole("button", { name: "変更を保存" }));
  fireEvent.click(screen.getByRole("button", { name: /Recording B/ }));
  await waitFor(() => expect(screen.getByLabelText("録音タイトル")).toHaveValue("Recording B"));
  await act(async () => { delayed.resolve(recording("A")); });
  expect(screen.getByLabelText("録音タイトル")).toHaveValue("Recording B");
});

it("reconnects the events socket and reloads detail, then cancels reconnect on unmount", async () => {
  vi.mocked(api.session).mockResolvedValue({ ...recording("A"), state: "transcribing", utterances: [] });
  const { unmount } = render(<App />);
  await screen.findByLabelText("録音タイトル");
  vi.useFakeTimers();
  const first = FakeSocket.instances[0];
  vi.mocked(api.session).mockResolvedValue(recording("A"));
  await act(async () => { first.onclose?.(); await vi.advanceTimersByTimeAsync(2000); });
  expect(FakeSocket.instances).toHaveLength(2);
  const second = FakeSocket.instances[1];
  await act(async () => { second.onopen?.(); });
  expect(screen.getByLabelText("0:00の発話")).toBeInTheDocument();
  await act(async () => { second.onclose?.(); });
  unmount();
  await act(async () => { await vi.advanceTimersByTimeAsync(5000); });
  expect(FakeSocket.instances).toHaveLength(2);
});
