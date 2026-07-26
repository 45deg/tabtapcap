from pathlib import Path

from local_transcriber.audio_protocol import FORMAT_PCM_S16LE, AudioFrame
from local_transcriber.capture import CaptureSession


class CountingWriter:
    def __init__(self) -> None:
        self.bytes_written = 0

    def write(self, data: bytes) -> None:
        self.bytes_written += len(data)

    def flush(self) -> None:
        pass

    def close(self) -> None:
        pass


def test_two_hour_capture_keeps_only_twelve_seconds_in_memory() -> None:
    sample_rate = 48_000
    chunk_samples = sample_rate // 2
    chunk = b"\0\0" * chunk_samples
    writer = CountingWriter()
    capture = CaptureSession(
        session_id="long-session",
        sample_rate=sample_rate,
        partial_path=Path("unused"),
        file=writer,
    )

    for sequence in range(2 * 60 * 60 * 2):
        capture.append(
            AudioFrame(
                sequence=sequence,
                start_sample=sequence * chunk_samples,
                sample_rate=sample_rate,
                channels=1,
                sample_format=FORMAT_PCM_S16LE,
                payload=chunk,
            )
        )

    assert capture.expected_sample == sample_rate * 2 * 60 * 60
    assert writer.bytes_written == capture.expected_sample * 2
    assert capture.recent_bytes <= sample_rate * 2 * 12
