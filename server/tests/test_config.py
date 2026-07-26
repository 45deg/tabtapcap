import pytest
from pydantic import ValidationError

from local_transcriber.config import FormattingConfig


def test_paragraph_pause_must_not_be_shorter_than_sentence_pause() -> None:
    with pytest.raises(ValidationError):
        FormattingConfig(sentence_pause_ms=2_000, paragraph_pause_ms=1_500)
