import type {
  AppSettings,
  Health,
  ModelInfo,
  ModelJob,
  SessionDetail,
  SessionSummary
} from "./types";

const runningInTauri =
  location.protocol === "tauri:" || location.hostname === "tauri.localhost";
export const SERVER_ORIGIN = runningInTauri ? "http://127.0.0.1:8765" : "";

async function connectionError(path: string, reason: unknown): Promise<Error> {
  const browserMessage = reason instanceof Error ? reason.message : String(reason);
  let appLog = "ブラウザ版ではアプリログを取得できません。";
  if (runningInTauri) {
    try {
      const { invoke } = await import("@tauri-apps/api/core");
      appLog = await invoke<string>("read_app_log");
    } catch (logError) {
      appLog = `アプリログの取得にも失敗しました: ${
        logError instanceof Error ? logError.message : String(logError)
      }`;
    }
  }
  return new Error(
    [
      "ローカルサーバーに接続できません。",
      `接続先: ${serverUrl(path)}`,
      `WebViewエラー: ${browserMessage}`,
      "",
      "アプリログ（末尾）:",
      appLog
    ].join("\n")
  );
}

export function serverUrl(path: string): string {
  return `${SERVER_ORIGIN}${path}`;
}

export function serverWebSocketUrl(path: string): string {
  if (SERVER_ORIGIN) return `${SERVER_ORIGIN.replace("http", "ws")}${path}`;
  const scheme = location.protocol === "https:" ? "wss" : "ws";
  return `${scheme}://${location.host}${path}`;
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  let response: Response;
  try {
    response = await fetch(serverUrl(path), {
      ...init,
      headers: {
        "Content-Type": "application/json",
        "X-Local-Client": "viewer",
        ...init?.headers
      }
    });
  } catch (reason) {
    throw await connectionError(path, reason);
  }
  if (!response.ok) {
    const body = await response.json().catch(() => ({ detail: response.statusText }));
    throw new Error(body.detail ?? "サーバーとの通信に失敗しました。");
  }
  if (response.status === 204) return undefined as T;
  return response.json() as Promise<T>;
}

export const api = {
  health: () => request<Health>("/api/v1/health"),
  settings: () => request<AppSettings>("/api/v1/settings"),
  updateSettings: (settings: AppSettings) =>
    request<AppSettings>("/api/v1/settings", {
      method: "PATCH",
      body: JSON.stringify(settings)
    }),
  deleteAllData: () => request<void>("/api/v1/data", { method: "DELETE" }),
  models: () => request<ModelInfo[]>("/api/v1/models"),
  downloadModel: (modelId: string) =>
    request<ModelJob>(`/api/v1/models/${modelId}/download`, {
      method: "POST",
      body: JSON.stringify({})
    }),
  modelJob: (jobId: string) => request<ModelJob>(`/api/v1/model-jobs/${jobId}`),
  cancelModelJob: (jobId: string) =>
    request<ModelJob>(`/api/v1/model-jobs/${jobId}/cancel`, { method: "POST" }),
  sessions: () => request<SessionSummary[]>("/api/v1/sessions"),
  session: (id: string) => request<SessionDetail>(`/api/v1/sessions/${id}`),
  renameSession: (session: SessionDetail, title: string) =>
    request<SessionDetail>(`/api/v1/sessions/${session.id}`, {
      method: "PATCH",
      body: JSON.stringify({ title, expected_revision: session.revision })
    }),
  renameSpeaker: (session: SessionDetail, speakerId: string, displayName: string) =>
    request<SessionDetail>(`/api/v1/sessions/${session.id}/speakers/${speakerId}`, {
      method: "PATCH",
      body: JSON.stringify({
        display_name: displayName,
        expected_revision: session.revision
      })
    }),
  updateUtterance: (
    session: SessionDetail,
    utteranceId: string,
    editedText: string,
    speakerId: string,
    paragraphBreakBefore: boolean
  ) =>
    request<SessionDetail>(`/api/v1/sessions/${session.id}/utterances/${utteranceId}`, {
      method: "PATCH",
      body: JSON.stringify({
        edited_text: editedText,
        speaker_id: speakerId,
        paragraph_break_before: paragraphBreakBefore,
        expected_revision: session.revision
      })
    }),
  reprocess: (id: string) =>
    request<{ status: string }>(`/api/v1/sessions/${id}/reprocess`, { method: "POST" }),
  deleteSession: (id: string) =>
    request<void>(`/api/v1/sessions/${id}`, { method: "DELETE" })
};
