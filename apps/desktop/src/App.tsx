import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { api, serverUrl, serverWebSocketUrl } from "./api";
import { Player } from "./components/Player";
import { ModelsPage } from "./components/ModelsPage";
import { SessionList } from "./components/SessionList";
import { SettingsPage } from "./components/SettingsPage";
import { Transcript } from "./components/Transcript";
import { stateLabel } from "./format";
import type { Health, SessionDetail, SessionEvent, SessionSummary, Utterance } from "./types";

export default function App() {
  const [view, setView] = useState<"recordings" | "models" | "settings">("recordings");
  const [health, setHealth] = useState<Health | null>(null);
  const [sessions, setSessions] = useState<SessionSummary[]>([]);
  const [selectedId, setSelectedId] = useState<string | null>(
    new URLSearchParams(location.search).get("session")
  );
  const [session, setSession] = useState<SessionDetail | null>(null);
  const [draft, setDraft] = useState("");
  const [currentTimeMs, setCurrentTimeMs] = useState(0);
  const [seekRequest, setSeekRequest] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [connecting, setConnecting] = useState(true);
  const connectionStartedAt = useRef(Date.now());

  const refreshList = useCallback(async () => {
    const next = await api.sessions();
    setSessions(next);
    setSelectedId((current) => current ?? next[0]?.id ?? null);
  }, []);

  const refreshSession = useCallback(async (id: string) => {
    const next = await api.session(id);
    setSession(next);
    setError(null);
  }, []);

  useEffect(() => {
    const refreshSystem = async () => {
      try {
        await Promise.all([api.health().then(setHealth), refreshList()]);
        setConnecting(false);
        setError((current) =>
          current?.startsWith("ローカルサーバーに接続できません。") ? null : current
        );
      } catch (reason) {
        setConnecting(true);
        if (Date.now() - connectionStartedAt.current >= 10_000) {
          setError(reason instanceof Error ? reason.message : String(reason));
        }
      }
    };
    void refreshSystem();
    const interval = window.setInterval(() => {
      void refreshSystem();
    }, 2_000);
    return () => window.clearInterval(interval);
  }, [refreshList]);

  useEffect(() => {
    if (connecting) return;
    if (!selectedId) {
      setSession(null);
      return;
    }
    history.replaceState(null, "", `?session=${selectedId}`);
    void refreshSession(selectedId).catch((reason: Error) => setError(reason.message));
  }, [connecting, selectedId, refreshSession]);

  useEffect(() => {
    if (connecting || !selectedId) return;
    const socket = new WebSocket(
      serverWebSocketUrl(`/ws/v1/events?sessionId=${selectedId}`)
    );
    socket.onmessage = (message) => {
      const event = JSON.parse(message.data) as SessionEvent;
      if (event.type === "draft") setDraft(event.text);
      if (event.type === "session_state") {
        setSession((current) =>
          current
            ? {
                ...current,
                state: event.state,
                progress: event.progress,
                revision: event.revision,
                error_code: event.errorCode,
                error_message: event.errorMessage
              }
            : current
        );
        if (event.state === "ready" || event.state === "error") {
          void refreshSession(selectedId);
          void refreshList();
        }
      }
    };
    return () => socket.close();
  }, [connecting, selectedId, refreshList, refreshSession]);

  const activeUtteranceId = useMemo(
    () =>
      session?.utterances.find(
        (utterance) => currentTimeMs >= utterance.start_ms && currentTimeMs < utterance.end_ms
      )?.id ?? null,
    [currentTimeMs, session]
  );

  async function runMutation(action: () => Promise<SessionDetail>): Promise<void> {
    try {
      const next = await action();
      setSession(next);
      await refreshList();
    } catch (reason) {
      const message = reason instanceof Error ? reason.message : String(reason);
      setError(message);
      if (message.includes("再読み込み") && selectedId) await refreshSession(selectedId);
    }
  }

  return (
    <div className="app-shell">
      <SessionList
        sessions={sessions}
        selectedId={selectedId}
        view={view}
        onViewChange={setView}
        onSelect={(id) => {
          setSelectedId(id);
          setView("recordings");
        }}
      />
      <main className="workspace">
        {error && (
          <div className="error-banner" role="alert">
            <div className="error-content">
              <strong>{error.split("\n")[0]}</strong>
              {error.includes("\n") && (
                <details>
                  <summary>診断情報を表示</summary>
                  <pre>{error.split("\n").slice(1).join("\n").trim()}</pre>
                </details>
              )}
            </div>
            <button type="button" onClick={() => setError(null)} aria-label="エラーを閉じる">
              ×
            </button>
          </div>
        )}
        {view === "models" ? (
          <ModelsPage onError={setError} />
        ) : view === "settings" ? (
          <SettingsPage
            onError={setError}
            onDataDeleted={async () => {
              setSelectedId(null);
              setSession(null);
              setDraft("");
              history.replaceState(null, "", location.pathname);
              await Promise.all([refreshList(), api.health().then(setHealth)]);
            }}
          />
        ) : !session ? (
          <div className="welcome">
            <h2>{connecting ? "ローカルサーバーを起動しています" : "録音を選択してください"}</h2>
            <p>
              {connecting
                ? "初回起動は少し時間がかかります。この画面のままお待ちください。"
                : "Chrome拡張から開始した録音を、ここで確認・編集できます。"}
            </p>
          </div>
        ) : (
          <>
            <header className="session-header">
              <div>
                <input
                  className="title-input"
                  aria-label="録音タイトル"
                  defaultValue={session.title}
                  key={`${session.id}-${session.revision}`}
                  onBlur={(event) => {
                    const value = event.currentTarget.value.trim();
                    if (value && value !== session.title) {
                      void runMutation(() => api.renameSession(session, value));
                    }
                  }}
                />
                <div className="session-status">
                  <span className={`state state-${session.state}`}>{stateLabel(session.state)}</span>
                  {session.state !== "ready" && session.state !== "error" && (
                    <progress value={session.progress} max={1}>
                      {Math.round(session.progress * 100)}%
                    </progress>
                  )}
                </div>
              </div>
              <div className="header-actions">
                {(["txt", "vtt", "json"] as const).map((format) => (
                  <a
                    key={format}
                    className="button secondary"
                    href={serverUrl(`/api/v1/sessions/${session.id}/export?format=${format}`)}
                    download
                  >
                    {format.toUpperCase()}
                  </a>
                ))}
                <button
                  type="button"
                  className="button danger"
                  onClick={async () => {
                    if (!confirm(`「${session.title}」と録音音声を削除しますか？`)) return;
                    await api.deleteSession(session.id);
                    setSelectedId(null);
                    setSession(null);
                    await refreshList();
                  }}
                >
                  削除
                </button>
              </div>
            </header>

            {health && !health.models.whisper && (
              <div className="notice">
                文字起こしモデルが未導入です。「モデル」画面からWhisperとVADを
                ダウンロードしてください。
              </div>
            )}

            {session.error_message && (
              <div className="error-card" role="alert">
                <strong>{session.error_message}</strong>
                <button
                  type="button"
                  className="button secondary"
                  onClick={async () => {
                    await api.reprocess(session.id);
                    await refreshSession(session.id);
                  }}
                >
                  再処理
                </button>
              </div>
            )}

            {draft && session.state === "capturing" && (
              <section className="live-draft" aria-live="polite">
                <span>ライブ</span>
                <p>{draft}</p>
              </section>
            )}

            {session.diarization_enabled && (
              <section className="speaker-editor" aria-label="話者名">
                {session.speakers.map((speaker) => (
                  <label key={speaker.id}>
                    <span>{speaker.id}</span>
                    <input
                      defaultValue={speaker.display_name}
                      key={`${speaker.id}-${session.revision}`}
                      onBlur={(event) => {
                        const value = event.currentTarget.value.trim();
                        if (value && value !== speaker.display_name) {
                          void runMutation(() =>
                            api.renameSpeaker(session, speaker.id, value)
                          );
                        }
                      }}
                    />
                  </label>
                ))}
              </section>
            )}

            <Transcript
              session={session}
              activeUtteranceId={activeUtteranceId}
              onSeek={(milliseconds) => {
                setSeekRequest(null);
                requestAnimationFrame(() => setSeekRequest(milliseconds));
              }}
              onSaveUtterance={async (
                utterance: Utterance,
                text,
                speakerId,
                paragraphBreakBefore
              ) => {
                await runMutation(() =>
                  api.updateUtterance(
                    session,
                    utterance.id,
                    text,
                    speakerId,
                    paragraphBreakBefore
                  )
                );
              }}
            />
            {(session.state === "ready" || session.state === "error") && (
              <Player
                sessionId={session.id}
                currentTimeMs={currentTimeMs}
                onTimeChange={setCurrentTimeMs}
                seekRequest={seekRequest}
              />
            )}
          </>
        )}
      </main>
    </div>
  );
}
