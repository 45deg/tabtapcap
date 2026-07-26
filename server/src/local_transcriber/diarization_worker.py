from __future__ import annotations

import json
import os
import sys
from pathlib import Path


def run(model_path: Path, audio_path: Path) -> list[dict[str, int | str]]:
    os.environ.setdefault("PYANNOTE_METRICS_ENABLED", "0")
    from pyannote.audio import Pipeline

    pipeline = Pipeline.from_pretrained(str(model_path))
    output = pipeline(str(audio_path))
    diarization = getattr(output, "exclusive_speaker_diarization", None)
    if diarization is None:
        diarization = output.speaker_diarization
    return [
        {
            "start_ms": round(turn.start * 1000),
            "end_ms": round(turn.end * 1000),
            "speaker_id": str(speaker).lower(),
        }
        for turn, _track, speaker in diarization.itertracks(yield_label=True)
    ]


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: diarization_worker MODEL_PATH AUDIO_PATH")
    print(json.dumps(run(Path(sys.argv[1]), Path(sys.argv[2]))))


if __name__ == "__main__":
    main()
