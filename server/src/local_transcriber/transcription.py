from __future__ import annotations

import asyncio
import json
import os
import sys
from pathlib import Path

import numpy as np

from .config import Settings
from .text_processing import RecognizedWord, SpeakerTurn


class ModelUnavailableError(RuntimeError):
    pass


class TranscriptionEngine:
    def __init__(self, config: Settings) -> None:
        self.config = config
        self._whisper = None
        self._whisper_lock = asyncio.Lock()

    @property
    def whisper_path(self) -> Path:
        return self.config.models_dir / "faster-whisper-small"

    @property
    def diarization_path(self) -> Path:
        return self.config.models_dir / "speaker-diarization-community-1"

    def model_status(self) -> dict[str, bool]:
        return {
            "whisper": self.whisper_path.exists() or self.config.fake_transcript,
            "diarization": self.diarization_path.exists() or self.config.fake_transcript,
        }

    def _load_whisper(self):
        if self._whisper is not None:
            return self._whisper
        if not self.whisper_path.exists():
            raise ModelUnavailableError(
                "Whisperモデルが未導入です。models downloadを実行してください。"
            )
        try:
            from faster_whisper import WhisperModel
        except ImportError as exc:
            raise ModelUnavailableError(
                "文字起こし依存が未導入です。uv sync --extra transcriptionを実行してください。"
            ) from exc
        self._whisper = WhisperModel(
            str(self.whisper_path),
            device="cpu",
            compute_type="int8",
            local_files_only=True,
        )
        return self._whisper

    async def transcribe_live(self, pcm: bytes, sample_rate: int, language: str) -> str | None:
        if self.config.fake_transcript:
            duration = len(pcm) / 2 / sample_rate
            return "ローカル文字起こしを確認しています。" if duration >= 2 else None
        if not self.whisper_path.exists() or self._whisper_lock.locked():
            return None
        audio = np.frombuffer(pcm, dtype="<i2").astype(np.float32) / 32768.0
        if sample_rate != 16_000 and len(audio):
            output_size = round(len(audio) * 16_000 / sample_rate)
            positions = np.linspace(0, len(audio) - 1, output_size)
            audio = np.interp(positions, np.arange(len(audio)), audio).astype(np.float32)
        async with self._whisper_lock:
            return await asyncio.to_thread(self._transcribe_live_sync, audio, language)

    def _transcribe_live_sync(self, audio: np.ndarray, language: str) -> str:
        model = self._load_whisper()
        segments, _ = model.transcribe(
            audio,
            language=None if language == "auto" else language,
            beam_size=1,
            temperature=0,
            vad_filter=True,
            condition_on_previous_text=False,
        )
        return "".join(segment.text for segment in segments).strip()

    async def transcribe_file(self, audio_path: Path, language: str) -> list[RecognizedWord]:
        if self.config.fake_transcript:
            return [
                RecognizedWord("これは", 500, 1_000, 0.99),
                RecognizedWord("ローカル文字起こしの", 1_000, 2_200, 0.99),
                RecognizedWord("確認用テキストです。", 2_200, 3_500, 0.99),
            ]
        async with self._whisper_lock:
            return await asyncio.to_thread(self._transcribe_file_sync, audio_path, language)

    def _transcribe_file_sync(self, audio_path: Path, language: str) -> list[RecognizedWord]:
        model = self._load_whisper()
        segments, _ = model.transcribe(
            str(audio_path),
            language=None if language == "auto" else language,
            beam_size=5,
            temperature=0,
            vad_filter=True,
            word_timestamps=True,
            condition_on_previous_text=True,
        )
        words: list[RecognizedWord] = []
        for segment in segments:
            for word in segment.words or []:
                words.append(
                    RecognizedWord(
                        text=word.word,
                        start_ms=round(word.start * 1000),
                        end_ms=round(word.end * 1000),
                        confidence=getattr(word, "probability", None),
                    )
                )
        return words

    async def diarize_file(self, audio_path: Path) -> list[SpeakerTurn]:
        if self.config.fake_transcript:
            return [SpeakerTurn(0, 60_000, "speaker_0")]
        if not self.diarization_path.exists():
            raise ModelUnavailableError(
                "話者分離モデルが未導入です。models download --diarizationを実行してください。"
            )
        environment = os.environ.copy()
        environment["PYANNOTE_METRICS_ENABLED"] = "0"
        worker_prefix = (
            [sys.executable, "_diarization_worker"]
            if getattr(sys, "frozen", False)
            else [sys.executable, "-m", "local_transcriber.diarization_worker"]
        )
        process = await asyncio.create_subprocess_exec(
            *worker_prefix,
            str(self.diarization_path),
            str(audio_path),
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=environment,
        )
        stdout, stderr = await process.communicate()
        if process.returncode:
            detail = stderr.decode(errors="replace").strip()
            if "No module named" in detail:
                raise ModelUnavailableError(
                    "話者分離依存が未導入です。uv sync --extra diarizationを実行してください。"
                )
            raise RuntimeError(f"話者分離に失敗しました: {detail}")
        payload = json.loads(stdout)
        return [SpeakerTurn(**turn) for turn in payload]
