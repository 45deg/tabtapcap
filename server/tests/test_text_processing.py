from local_transcriber.text_processing import (
    RecognizedWord,
    SpeakerTurn,
    assign_speakers,
    group_utterances,
)


def test_assigns_speaker_by_largest_overlap() -> None:
    words = [
        RecognizedWord("こんにちは。", 0, 900),
        RecognizedWord("はい。", 1_100, 1_500),
    ]
    turns = [
        SpeakerTurn(0, 1_000, "speaker_0"),
        SpeakerTurn(1_000, 2_000, "speaker_1"),
    ]
    assign_speakers(words, turns)
    assert [word.speaker_id for word in words] == ["speaker_0", "speaker_1"]


def test_groups_on_speaker_change_and_long_silence() -> None:
    words = [
        RecognizedWord("最初です。", 0, 500, speaker_id="speaker_0"),
        RecognizedWord("続きです。", 700, 1_200, speaker_id="speaker_0"),
        RecognizedWord("返答です。", 1_300, 1_800, speaker_id="speaker_1"),
        RecognizedWord("別の話題です。", 4_000, 5_000, speaker_id="speaker_1"),
    ]
    utterances = group_utterances(words)
    assert [item.text for item in utterances] == [
        "最初です。続きです。",
        "返答です。",
        "別の話題です。",
    ]
    assert all(item.paragraph_break_before for item in utterances)


def test_adds_japanese_punctuation_and_splits_sentences_from_pauses() -> None:
    words = [
        RecognizedWord("今日は", 0, 300),
        RecognizedWord("確認します", 900, 1_300),
        RecognizedWord("次の話題です", 2_600, 3_200),
        RecognizedWord("補足します", 4_500, 5_000),
    ]

    utterances = group_utterances(words)

    assert [item.text for item in utterances] == [
        "今日は、確認します。",
        "次の話題です。",
        "補足します。",
    ]
    assert [item.paragraph_break_before for item in utterances] == [True, False, False]


def test_creates_paragraph_after_two_second_pause_without_diarization() -> None:
    words = [
        RecognizedWord("最初の文", 0, 500),
        RecognizedWord("新しい段落", 2_600, 3_200),
    ]

    utterances = group_utterances(words)

    assert [item.text for item in utterances] == ["最初の文。", "新しい段落。"]
    assert [item.paragraph_break_before for item in utterances] == [True, True]
