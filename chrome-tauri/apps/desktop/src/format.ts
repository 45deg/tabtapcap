export function formatDuration(milliseconds: number): string {
  const totalSeconds = Math.max(0, Math.floor(milliseconds / 1000));
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;
  return hours > 0
    ? `${hours}:${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`
    : `${minutes}:${String(seconds).padStart(2, "0")}`;
}

export function formatDate(iso: string): string {
  return new Intl.DateTimeFormat("ja-JP", {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit"
  }).format(new Date(iso));
}

export function stateLabel(state: string): string {
  const labels: Record<string, string> = {
    capturing: "録音中",
    finalizing: "音声を準備中",
    transcribing: "文字起こし中",
    diarizing: "話者を解析中",
    formatting: "文章を整形中",
    ready: "完了",
    interrupted: "中断",
    error: "エラー"
  };
  return labels[state] ?? state;
}

