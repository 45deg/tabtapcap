import { formatDate, formatDuration, stateLabel } from "../format";
import type { SessionSummary } from "../types";

interface Props {
  sessions: SessionSummary[];
  selectedId: string | null;
  onSelect: (id: string) => void;
  view: "recordings" | "models" | "settings";
  onViewChange: (view: Props["view"]) => void;
}

export function SessionList({
  sessions,
  selectedId,
  onSelect,
  view,
  onViewChange
}: Props) {
  return (
    <nav className="session-list" aria-label="アプリケーション">
      <div className="app-navigation">
        <button
          type="button"
          className={view === "recordings" ? "selected" : ""}
          onClick={() => onViewChange("recordings")}
        >
          録音
        </button>
        <button
          type="button"
          className={view === "models" ? "selected" : ""}
          onClick={() => onViewChange("models")}
        >
          モデル
        </button>
        <button
          type="button"
          className={view === "settings" ? "selected" : ""}
          onClick={() => onViewChange("settings")}
        >
          設定
        </button>
      </div>
      {view === "recordings" && (
        <>
      <div className="sidebar-heading">
        <h1>録音</h1>
        <span>{sessions.length}</span>
      </div>
      {sessions.length === 0 ? (
        <p className="empty-sidebar">拡張機能から録音を開始すると、ここに表示されます。</p>
      ) : (
        <ul>
          {sessions.map((session) => (
            <li key={session.id}>
              <button
                type="button"
                className={session.id === selectedId ? "session-item selected" : "session-item"}
                aria-current={session.id === selectedId ? "page" : undefined}
                onClick={() => onSelect(session.id)}
              >
                <strong>{session.title}</strong>
                <span>
                  {formatDate(session.created_at)} · {formatDuration(session.duration_ms)}
                </span>
                <span className={`state state-${session.state}`}>{stateLabel(session.state)}</span>
              </button>
            </li>
          ))}
        </ul>
      )}
        </>
      )}
    </nav>
  );
}
