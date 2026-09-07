import { afterEach, expect, it, vi } from "vitest";

type Reply = { status?: string; ok?: boolean; message?: string; sessionId?: string };
type Listener = (message: unknown, sender: unknown, reply: (value: Reply) => void) => void;

afterEach(() => { vi.unstubAllGlobals(); });

it("preserves the session on stop failure and retries stopping instead of starting over", async () => {
  vi.resetModules();
  let listener!: Listener;
  const store = vi.fn().mockResolvedValue(undefined);
  const offscreen = vi.fn()
    .mockResolvedValueOnce({ ok: false, message: "Disconnected" })
    .mockResolvedValueOnce({ ok: true });
  vi.stubGlobal("chrome", {
    storage: { session: {
      get: async () => ({ recordingState: { status: "recording", sessionId: "session-1", startedAt: 0, tabTitle: "Tab" } }),
      set: store
    } },
    action: { setBadgeText: vi.fn(), setBadgeBackgroundColor: vi.fn() },
    runtime: { onMessage: { addListener: (next: Listener) => { listener = next; } }, sendMessage: offscreen }
  });
  await import("./service-worker");
  const send = (type: string) => new Promise<Reply>((resolve) => listener({ type }, {}, resolve));
  expect((await send("STOP_CAPTURE")).ok).toBe(false);
  expect(await send("GET_STATE")).toMatchObject({ status: "error", sessionId: "session-1" });
  expect(await send("STOP_CAPTURE")).toEqual({ status: "idle" });
  expect(offscreen).toHaveBeenCalledTimes(2);
});
