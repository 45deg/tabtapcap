import { useEffect, useState } from "react";
import { formatDuration } from "../format";

const METER_BAR_COUNT = 24;
const EMPTY_HISTORY = Array.from({ length: METER_BAR_COUNT }, () => 0);

export function RecordingStatus({
  startedAt,
  title,
  level,
  levelSequence
}: {
  startedAt: string;
  title: string;
  level: number;
  levelSequence: number;
}) {
  const [now, setNow] = useState(() => Date.now());
  const [levelHistory, setLevelHistory] = useState(EMPTY_HISTORY);

  useEffect(() => {
    const timer = window.setInterval(() => setNow(Date.now()), 1_000);
    return () => window.clearInterval(timer);
  }, []);

  useEffect(() => {
    const nextLevel = Math.min(1, Math.max(0, level));
    setLevelHistory((current) => [...current.slice(1), nextLevel]);
  }, [level, levelSequence]);

  useEffect(() => {
    setLevelHistory(EMPTY_HISTORY);
  }, [startedAt]);

  const elapsed = Math.max(0, now - Date.parse(startedAt));

  return (
    <section className="recording-status" aria-label={`${title}を録音中`}>
      <div className="recording-status-copy">
        <span className="recording-label">
          <span className="recording-dot" aria-hidden="true" />
          録音中
        </span>
        <strong>タブの音声を録音しています</strong>
      </div>
      <div className="recording-meter" aria-hidden="true">
        {levelHistory.map((historyLevel, index) => (
          <span
            key={index}
            style={{ height: `${8 + historyLevel * 92}%` }}
          />
        ))}
      </div>
      <time dateTime={`PT${Math.floor(elapsed / 1_000)}S`}>
        {formatDuration(elapsed)}
      </time>
    </section>
  );
}
