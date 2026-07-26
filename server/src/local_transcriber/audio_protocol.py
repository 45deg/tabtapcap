from __future__ import annotations

import struct
from dataclasses import dataclass

MAGIC = b"LTCA"
VERSION = 1
FORMAT_PCM_S16LE = 1
HEADER = struct.Struct("<4sBBHIQIBBH")
HEADER_SIZE = HEADER.size


class AudioFrameError(ValueError):
    pass


@dataclass(frozen=True, slots=True)
class AudioFrame:
    sequence: int
    start_sample: int
    sample_rate: int
    channels: int
    sample_format: int
    payload: bytes
    flags: int = 0

    @property
    def sample_count(self) -> int:
        bytes_per_sample = 2
        return len(self.payload) // (bytes_per_sample * self.channels)


def decode_audio_frame(data: bytes) -> AudioFrame:
    if len(data) < HEADER_SIZE:
        raise AudioFrameError("audio frame is shorter than its header")
    (
        magic,
        version,
        flags,
        header_length,
        sequence,
        start_sample,
        sample_rate,
        channels,
        sample_format,
        _reserved,
    ) = HEADER.unpack_from(data)
    if magic != MAGIC:
        raise AudioFrameError("invalid audio frame magic")
    if version != VERSION:
        raise AudioFrameError(f"unsupported audio protocol version: {version}")
    if header_length != HEADER_SIZE:
        raise AudioFrameError(f"invalid audio header length: {header_length}")
    if channels != 1:
        raise AudioFrameError("only mono audio is supported")
    if sample_format != FORMAT_PCM_S16LE:
        raise AudioFrameError("only PCM16LE audio is supported")
    if sample_rate < 8_000 or sample_rate > 192_000:
        raise AudioFrameError("sample rate is outside the supported range")
    payload = data[header_length:]
    if not payload or len(payload) % 2:
        raise AudioFrameError("PCM16 payload must contain complete samples")
    return AudioFrame(
        sequence=sequence,
        start_sample=start_sample,
        sample_rate=sample_rate,
        channels=channels,
        sample_format=sample_format,
        payload=payload,
        flags=flags,
    )


def encode_audio_frame(frame: AudioFrame) -> bytes:
    return (
        HEADER.pack(
            MAGIC,
            VERSION,
            frame.flags,
            HEADER_SIZE,
            frame.sequence,
            frame.start_sample,
            frame.sample_rate,
            frame.channels,
            frame.sample_format,
            0,
        )
        + frame.payload
    )
