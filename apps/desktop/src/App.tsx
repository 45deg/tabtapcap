import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { X } from "lucide-react";
import { api, saveExportFile, serverWebSocketUrl } from "./api";
import { Player } from "./components/Player";
import { ModelsPage } from "./components/ModelsPage";
import { RecordingStatus } from "./components/RecordingStatus";
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
  const [audioLevel, setAudioLevel] = useState({ sequence: 0, level: 0 });
  const [currentTimeMs, setCurrentTimeMs] = useState(0);
  const [seekRequest, setSeekRequest] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [feedback, setFeedback] = useState<string | null>(null);
  const [activeAction, setActiveAction] = useState<string | null>(null);
  const [confirmingDelete, setConfirmingDelete] = useState(false);
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
      if (event.type === "audio_level") {
        setAudioLevel({ sequence: event.sequence, level: event.level });
      }
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

  useEffect(() => {
    setConfirmingDelete(false);
    setActiveAction(null);
    setAudioLevel({ sequence: 0, level: 0 });
  }, [selectedId]);

  async function runSessionAction(action: string, operation: () => Promise<void>): Promise<void> {
    if (activeAction) return;
    setActiveAction(action);
    setError(null);
    setFeedback(null);
    try {
      await operation();
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : String(reason));
    } finally {
      setActiveAction(null);
    }
  }

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
        onOpenSettings={() => setView("settings")}
        onSelect={(id) => {
          setFeedback(null);
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
              <X aria-hidden="true" />
            </button>
          </div>
        )}
        {feedback && (
          <div className="success-banner" role="status">
            <span>{feedback}</span>
            <button
              type="button"
              onClick={() => setFeedback(null)}
              aria-label="通知を閉じる"
            >
              <X aria-hidden="true" />
            </button>
          </div>
        )}
        {view === "models" ? (
          <section className="management-view">
            <nav className="management-tabs" aria-label="管理画面">
              <button type="button" className="selected" aria-current="page">
                モデル
              </button>
              <button type="button" onClick={() => setView("settings")}>
                設定
              </button>
            </nav>
            <ModelsPage onError={setError} />
          </section>
        ) : view === "settings" ? (
          <section className="management-view">
            <nav className="management-tabs" aria-label="管理画面">
              <button type="button" onClick={() => setView("models")}>
                モデル
              </button>
              <button type="button" className="selected" aria-current="page">
                設定
              </button>
            </nav>
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
          </section>
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
                  <button
                    type="button"
                    key={format}
                    className="button secondary"
                    disabled={activeAction !== null}
                    onClick={() =>
                      void runSessionAction(`export-${format}`, async () => {
                        const contents = await api.exportSession(session.id, format);
                        const savedPath = await saveExportFile(session.title, format, contents);
                        setFeedback(`${format.toUpperCase()}を保存しました: ${savedPath}`);
                      })
                    }
                  >
                    {activeAction === `export-${format}` ? "保存中…" : format.toUpperCase()}
                  </button>
                ))}
                <button
                  type="button"
                  className="button danger"
                  disabled={activeAction !== null}
                  onClick={() => setConfirmingDelete(true)}
                >
                  削除
                </button>
              </div>
            </header>

            {session.state === "capturing" && (
              <RecordingStatus
                startedAt={session.created_at}
                title={session.title}
                level={audioLevel.level}
                levelSequence={audioLevel.sequence}
              />
            )}

            {confirmingDelete && (
              <section
                className="delete-confirmation"
                role="alertdialog"
                aria-labelledby="delete-confirmation-title"
                aria-describedby="delete-confirmation-description"
              >
                <div>
                  <strong id="delete-confirmation-title">この録音を削除しますか？</strong>
                  <p id="delete-confirmation-description">
                    「{session.title}」の文字起こしと録音音声を削除します。この操作は元に戻せません。
                  </p>
                </div>
                <div className="delete-confirmation-actions">
                  <button
                    type="button"
                    className="button secondary"
                    disabled={activeAction !== null}
                    onClick={() => setConfirmingDelete(false)}
                  >
                    キャンセル
                  </button>
                  <button
                    type="button"
                    className="button danger"
                    disabled={activeAction !== null}
                    onClick={() =>
                      void runSessionAction("delete", async () => {
                        await api.deleteSession(session.id);
                        setConfirmingDelete(false);
                        setSelectedId(null);
                        setSession(null);
                        await refreshList();
                        setFeedback("録音を削除しました。");
                      })
                    }
                  >
                    {activeAction === "delete" ? "削除中…" : "削除する"}
                  </button>
                </div>
              </section>
            )}

            {health &&
              (!health.models.transcription ||
                (health.models.whisper && !health.models.vad)) && (
                <div className="notice">
                  {!health.models.transcription
                    ? "選択した文字起こしモデルが未導入です。「モデル」画面からダウンロードしてください。"
                    : "Whisperに必要なSilero VADが未導入です。「モデル」画面からダウンロードしてください。"}
                </div>
              )}

            {session.error_message && (
              <div className="error-card" role="alert">
                <strong>{session.error_message}</strong>
                <button
                  type="button"
                  className="button secondary"
                  disabled={activeAction !== null}
                  onClick={() =>
                    void runSessionAction("reprocess", async () => {
                      await api.reprocess(session.id);
                      await refreshSession(session.id);
                      setFeedback("再処理を開始しました。");
                    })
                  }
                >
                  {activeAction === "reprocess" ? "開始中…" : "再処理"}
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
