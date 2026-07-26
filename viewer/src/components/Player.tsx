import { useEffect, useRef } from "react";
import { formatDuration } from "../format";

interface Props {
  sessionId: string;
  currentTimeMs: number;
  onTimeChange: (milliseconds: number) => void;
  seekRequest: number | null;
}

export function Player({ sessionId, currentTimeMs, onTimeChange, seekRequest }: Props) {
  const ref = useRef<HTMLAudioElement>(null);

  useEffect(() => {
    if (seekRequest === null || !ref.current) return;
    ref.current.currentTime = seekRequest / 1000;
    void ref.current.play();
  }, [seekRequest]);

  return (
    <footer className="player-bar">
      <audio
        ref={ref}
        controls
        src={`/api/v1/sessions/${sessionId}/audio`}
        onTimeUpdate={(event) => onTimeChange(event.currentTarget.currentTime * 1000)}
      />
      <output aria-live="off">{formatDuration(currentTimeMs)}</output>
    </footer>
  );
}

