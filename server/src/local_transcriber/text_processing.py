from __future__ import annotations

from dataclasses import dataclass, field

TERMINAL_PUNCTUATION = ("。", "！", "？", "!", "?")
PAUSE_PUNCTUATION = TERMINAL_PUNCTUATION + ("、", "，", ",", "：", ":")
SENTENCE_GAP_MS = 1_200
PARAGRAPH_GAP_MS = 2_000
COMMA_GAP_MS = 500
MAX_PARAGRAPH_CHARS = 320


@dataclass(slots=True)
class RecognizedWord:
    text: str
    start_ms: int
    end_ms: int
    confidence: float | None = None
    speaker_id: str = "speaker_0"


@dataclass(slots=True)
class SpeakerTurn:
    start_ms: int
    end_ms: int
    speaker_id: str


@dataclass(slots=True)
class UtteranceDraft:
    speaker_id: str
    start_ms: int
    end_ms: int
    text: str
    words: list[RecognizedWord] = field(default_factory=list)
    paragraph_break_before: bool = True
    confidence: float | None = None


def assign_speakers(words: list[RecognizedWord], turns: list[SpeakerTurn]) -> None:
    if not turns:
        return
    for word in words:
        midpoint = (word.start_ms + word.end_ms) / 2

        def score(
            turn: SpeakerTurn,
            word_start: int = word.start_ms,
            word_end: int = word.end_ms,
            word_midpoint: float = midpoint,
        ) -> tuple[int, float]:
            overlap = max(0, min(word_end, turn.end_ms) - max(word_start, turn.start_ms))
            turn_midpoint = (turn.start_ms + turn.end_ms) / 2
            return overlap, -abs(word_midpoint - turn_midpoint)

        word.speaker_id = max(turns, key=score).speaker_id


def _mean_confidence(words: list[RecognizedWord]) -> float | None:
    values = [word.confidence for word in words if word.confidence is not None]
    return sum(values) / len(values) if values else None


def format_words(
    words: list[RecognizedWord], comma_gap_ms: int = COMMA_GAP_MS
) -> str:
    """Join recognized words while adding punctuation only at audible pauses."""
    if not words:
        return ""
    parts: list[str] = []
    for index, word in enumerate(words):
        if index:
            previous = words[index - 1]
            gap = max(0, word.start_ms - previous.end_ms)
            previous_text = previous.text.rstrip()
            next_text = word.text.lstrip()
            if (
                gap >= comma_gap_ms
                and previous_text
                and not previous_text.endswith(PAUSE_PUNCTUATION)
                and not next_text.startswith(PAUSE_PUNCTUATION)
            ):
                parts.append("、")
        parts.append(word.text)
    text = "".join(parts).strip()
    if text and not text.endswith(TERMINAL_PUNCTUATION):
        text = text.rstrip("、，,") + "。"
    return text


def group_utterances(
    words: list[RecognizedWord],
    max_chars: int = 160,
    *,
    comma_gap_ms: int = COMMA_GAP_MS,
    sentence_gap_ms: int = SENTENCE_GAP_MS,
    paragraph_gap_ms: int = PARAGRAPH_GAP_MS,
    max_paragraph_chars: int = MAX_PARAGRAPH_CHARS,
) -> list[UtteranceDraft]:
    if not words:
        return []
    results: list[UtteranceDraft] = []
    current: list[RecognizedWord] = []

    def flush(paragraph_break: bool = True) -> None:
        nonlocal current
        if not current:
            return
        text = format_words(current, comma_gap_ms)
        if text:
            results.append(
                UtteranceDraft(
                    speaker_id=current[0].speaker_id,
                    start_ms=current[0].start_ms,
                    end_ms=current[-1].end_ms,
                    text=text,
                    words=current,
                    paragraph_break_before=paragraph_break,
                    confidence=_mean_confidence(current),
                )
            )
        current = []

    for word in words:
        if not current:
            current.append(word)
            continue
        previous = current[-1]
        gap = max(0, word.start_ms - previous.end_ms)
        text_length = sum(len(item.text) for item in current)
        should_split = (
            word.speaker_id != previous.speaker_id
            or gap >= sentence_gap_ms
            or text_length + len(word.text) > max_chars
        )
        if should_split:
            flush()
        current.append(word)
    flush()

    paragraph_chars = 0
    for index, utterance in enumerate(results):
        if index == 0:
            utterance.paragraph_break_before = True
            paragraph_chars = len(utterance.text)
            continue
        previous = results[index - 1]
        gap = utterance.start_ms - previous.end_ms
        utterance.paragraph_break_before = (
            utterance.speaker_id != previous.speaker_id
            or gap >= paragraph_gap_ms
            or paragraph_chars + len(utterance.text) > max_paragraph_chars
        )
        if utterance.paragraph_break_before:
            paragraph_chars = len(utterance.text)
        else:
            paragraph_chars += len(utterance.text)
    return results
