import { Settings } from "lucide-react";
import { formatDate, formatDuration, stateLabel } from "../format";
import type { SessionSummary } from "../types";

interface Props {
  sessions: SessionSummary[];
  selectedId: string | null;
  onSelect: (id: string) => void;
  view: "recordings" | "models" | "settings";
  onOpenSettings: () => void;
}

export function SessionList({
  sessions,
  selectedId,
  onSelect,
  view,
  onOpenSettings
}: Props) {
  return (
    <nav className="session-list" aria-label="アプリケーション">
      <div className="session-list-content">
        <div className="sidebar-heading">
          <h1>録音</h1>
          <span>{sessions.length}</span>
        </div>
        {sessions.length === 0 ? (
          <p className="empty-sidebar">
            拡張機能から録音を開始すると、ここに表示されます。
          </p>
        ) : (
          <ul>
            {sessions.map((session) => (
              <li key={session.id}>
                <button
                  type="button"
                  className={
                    view === "recordings" && session.id === selectedId
                      ? "session-item selected"
                      : "session-item"
                  }
                  aria-current={
                    view === "recordings" && session.id === selectedId
                      ? "page"
                      : undefined
                  }
                  onClick={() => onSelect(session.id)}
                >
                  <strong>{session.title}</strong>
                  <span>
                    {formatDate(session.created_at)} ·{" "}
                    {formatDuration(session.duration_ms)}
                  </span>
                  <span className={`state state-${session.state}`}>
                    {stateLabel(session.state)}
                  </span>
                </button>
              </li>
            ))}
          </ul>
        )}
      </div>
      <div className="sidebar-footer">
        <button
          type="button"
          className={
            view === "settings" || view === "models"
              ? "settings-button selected"
              : "settings-button"
          }
          aria-label="設定を開く"
          aria-current={view === "settings" || view === "models" ? "page" : undefined}
          onClick={onOpenSettings}
        >
          <Settings aria-hidden="true" />
          <span>設定</span>
        </button>
      </div>
    </nav>
  );
}
