export interface SessionSummary {
  id: string;
  title: string;
  state: string;
  language: string;
  diarization_enabled: boolean;
  total_samples: number;
  sample_rate: number;
  revision: number;
  progress: number;
  audio_gap: boolean;
  created_at: string;
  stopped_at: string | null;
  error_code: string | null;
  error_message: string | null;
  duration_ms: number;
}

export interface Speaker {
  id: string;
  display_name: string;
  position: number;
}

export interface Utterance {
  id: string;
  speaker_id: string;
  position: number;
  start_ms: number;
  end_ms: number;
  raw_text: string;
  edited_text: string | null;
  paragraph_break_before: boolean;
  confidence: number | null;
}

export interface SessionDetail extends SessionSummary {
  tab_url: string | null;
  speakers: Speaker[];
  utterances: Utterance[];
}

export interface Health {
  status: "ok" | "degraded";
  version: string;
  models: Record<string, boolean>;
  active_session_id: string | null;
}

export type SessionEvent =
  | {
      type: "draft";
      sessionId: string;
      draftId: string;
      revision: number;
      startMs: number;
      endMs: number;
      text: string;
    }
  | {
      type: "session_state";
      sessionId: string;
      state: string;
      progress: number;
      revision: number;
      errorCode: string | null;
      errorMessage: string | null;
    };
