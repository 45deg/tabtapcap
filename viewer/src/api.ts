import type { Health, SessionDetail, SessionSummary } from "./types";

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(path, {
    ...init,
    headers: {
      "Content-Type": "application/json",
      ...init?.headers
    }
  });
  if (!response.ok) {
    const body = await response.json().catch(() => ({ detail: response.statusText }));
    throw new Error(body.detail ?? "サーバーとの通信に失敗しました。");
  }
  if (response.status === 204) return undefined as T;
  return response.json() as Promise<T>;
}

export const api = {
  health: () => request<Health>("/api/v1/health"),
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

