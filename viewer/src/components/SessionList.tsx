import { formatDate, formatDuration, stateLabel } from "../format";
import type { SessionSummary } from "../types";

interface Props {
  sessions: SessionSummary[];
  selectedId: string | null;
  onSelect: (id: string) => void;
}

export function SessionList({ sessions, selectedId, onSelect }: Props) {
  return (
    <nav className="session-list" aria-label="録音一覧">
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
    </nav>
  );
}

