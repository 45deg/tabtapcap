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

export interface TranscriptionSettings {
  language: "ja" | "auto";
  model_id:
    | "whisper-tiny"
    | "whisper-base"
    | "whisper-small"
    | "whisper-medium"
    | "whisper-large-v3"
    | "whisper-large-v3-turbo"
    | "parakeet-tdt-0.6b-ja";
  diarization_default: boolean;
}

export interface FormattingSettings {
  comma_pause_ms: number;
  sentence_pause_ms: number;
  paragraph_pause_ms: number;
  max_paragraph_chars: number;
}

export interface AppSettings {
  transcription: TranscriptionSettings;
  formatting: FormattingSettings;
}

export interface ModelInfo {
  id: string;
  name: string;
  engine: "whisper" | "parakeet" | "utility";
  repo_id: string;
  revision: string;
  requires_token: boolean;
  purpose: string;
  approximate_size_bytes: number | null;
  installed: boolean;
  job_id: string | null;
  job_state: string | null;
  job_phase: string | null;
}

export interface ModelJob {
  id: string;
  model_id: string;
  state: string;
  phase: string;
  progress: number | null;
  error_code: string | null;
  error_message: string | null;
  created_at: string;
  completed_at: string | null;
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
      type: "audio_level";
      sessionId: string;
      sequence: number;
      level: number;
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
