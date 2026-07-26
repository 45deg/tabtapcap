from local_transcriber.audio_protocol import (
    FORMAT_PCM_S16LE,
    AudioFrame,
    decode_audio_frame,
    encode_audio_frame,
)


def test_audio_frame_round_trip() -> None:
    original = AudioFrame(
        sequence=42,
        start_sample=96_000,
        sample_rate=48_000,
        channels=1,
        sample_format=FORMAT_PCM_S16LE,
        payload=b"\x00\x00\x01\x00\xff\xff",
    )
    decoded = decode_audio_frame(encode_audio_frame(original))
    assert decoded == original
    assert decoded.sample_count == 3
