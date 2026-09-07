import { useState } from "react";
import { formatDuration } from "../format";
import type { SessionDetail, Utterance } from "../types";

interface Props {
  session: SessionDetail;
  activeUtteranceId: string | null;
  onSeek: (milliseconds: number) => void;
  onSaveUtterance: (
    utterance: Utterance,
    text: string,
    speakerId: string,
    paragraphBreakBefore: boolean
  ) => Promise<boolean>;
}

function UtteranceEditor({
  utterance,
  session,
  active,
  onSeek,
  onSave
}: {
  utterance: Utterance;
  session: SessionDetail;
  active: boolean;
  onSeek: () => void;
  onSave: Props["onSaveUtterance"];
}) {
  const [edits, setEdits] = useState<{
    text?: string;
    speakerId?: string;
    paragraphBreak?: boolean;
  }>({});
  const text = edits.text ?? utterance.edited_text ?? utterance.raw_text;
  const speakerId = edits.speakerId ?? utterance.speaker_id;
  const paragraphBreak = edits.paragraphBreak ?? utterance.paragraph_break_before;
  const [saving, setSaving] = useState(false);

  const changed =
    text !== (utterance.edited_text ?? utterance.raw_text) ||
    speakerId !== utterance.speaker_id ||
    paragraphBreak !== utterance.paragraph_break_before;

  return (
    <article className={`utterance ${active ? "active" : ""}`}>
      <div className="utterance-meta">
        <button type="button" className="timestamp" onClick={onSeek}>
          {formatDuration(utterance.start_ms)}
        </button>
        {session.diarization_enabled && (
          <label>
            <span className="sr-only">話者</span>
            <select value={speakerId} onChange={(event) => setEdits({ ...edits, speakerId: event.target.value })}>
              {session.speakers.map((speaker) => (
                <option key={speaker.id} value={speaker.id}>
                  {speaker.display_name}
                </option>
              ))}
            </select>
          </label>
        )}
        <label className="paragraph-toggle">
          <input
            type="checkbox"
            checked={paragraphBreak}
            onChange={(event) => setEdits({ ...edits, paragraphBreak: event.target.checked })}
          />
          段落
        </label>
      </div>
      <textarea
        value={text}
        onChange={(event) => setEdits({ ...edits, text: event.target.value })}
        aria-label={`${formatDuration(utterance.start_ms)}の発話`}
        rows={Math.max(2, Math.ceil(text.length / 44))}
      />
      {changed && (
        <button
          type="button"
          className="save-button"
          disabled={saving}
          onClick={async () => {
            setSaving(true);
            try {
              if (await onSave(utterance, text, speakerId, paragraphBreak)) {
                // Keep any changes typed while this save was in flight.
                setEdits((current) => ({
                  text: current.text === text ? undefined : current.text,
                  speakerId: current.speakerId === speakerId ? undefined : current.speakerId,
                  paragraphBreak: current.paragraphBreak === paragraphBreak ? undefined : current.paragraphBreak
                }));
              }
            } finally {
              setSaving(false);
            }
          }}
        >
          {saving ? "保存中…" : "変更を保存"}
        </button>
      )}
    </article>
  );
}

export function Transcript({
  session,
  activeUtteranceId,
  onSeek,
  onSaveUtterance
}: Props) {
  if (session.utterances.length === 0) {
    return <p className="empty-transcript">確定した発話はまだありません。</p>;
  }
  return (
    <section className="transcript" aria-label="文字起こし">
      {session.utterances.map((utterance) => (
        <UtteranceEditor
          key={utterance.id}
          utterance={utterance}
          session={session}
          active={activeUtteranceId === utterance.id}
          onSeek={() => onSeek(utterance.start_ms)}
          onSave={onSaveUtterance}
        />
      ))}
    </section>
  );
}
