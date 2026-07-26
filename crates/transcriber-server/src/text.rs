use crate::types::{FormattingSettings, RecognizedWord, UtteranceDraft};

const TERMINAL: &[char] = &['。', '！', '？', '!', '?'];
const PAUSE: &[char] = &['。', '！', '？', '!', '?', '、', '，', ',', '：', ':'];

fn ends_with_any(text: &str, chars: &[char]) -> bool {
    text.chars()
        .last()
        .is_some_and(|value| chars.contains(&value))
}

fn starts_with_any(text: &str, chars: &[char]) -> bool {
    text.chars()
        .next()
        .is_some_and(|value| chars.contains(&value))
}

pub fn format_words(words: &[RecognizedWord], comma_gap_ms: i64) -> String {
    let mut result = String::new();
    for (index, word) in words.iter().enumerate() {
        if index > 0 {
            let previous = &words[index - 1];
            let gap = (word.start_ms - previous.end_ms).max(0);
            let previous_text = previous.text.trim_end();
            let next_text = word.text.trim_start();
            if gap >= comma_gap_ms
                && !previous_text.is_empty()
                && !ends_with_any(previous_text, PAUSE)
                && !starts_with_any(next_text, PAUSE)
            {
                result.push('、');
            }
        }
        result.push_str(&word.text);
    }
    let mut result = result.trim().to_string();
    if !result.is_empty() && !ends_with_any(&result, TERMINAL) {
        while result.ends_with(['、', '，', ',']) {
            result.pop();
        }
        result.push('。');
    }
    result
}

pub fn group_utterances(
    words: &[RecognizedWord],
    settings: &FormattingSettings,
) -> Vec<UtteranceDraft> {
    let mut results = Vec::new();
    let mut current: Vec<RecognizedWord> = Vec::new();

    let flush = |items: &mut Vec<RecognizedWord>, results: &mut Vec<UtteranceDraft>| {
        if items.is_empty() {
            return;
        }
        let text = format_words(items, settings.comma_pause_ms);
        if !text.is_empty() {
            let confidence_values: Vec<f64> =
                items.iter().filter_map(|item| item.confidence).collect();
            results.push(UtteranceDraft {
                start_ms: items[0].start_ms,
                end_ms: items.last().map_or(items[0].end_ms, |item| item.end_ms),
                text,
                paragraph_break_before: true,
                confidence: (!confidence_values.is_empty()).then(|| {
                    confidence_values.iter().sum::<f64>() / confidence_values.len() as f64
                }),
            });
        }
        items.clear();
    };

    for word in words {
        if let Some(previous) = current.last() {
            let gap = (word.start_ms - previous.end_ms).max(0);
            let current_chars: usize = current.iter().map(|item| item.text.chars().count()).sum();
            if gap >= settings.sentence_pause_ms || current_chars + word.text.chars().count() > 160
            {
                flush(&mut current, &mut results);
            }
        }
        current.push(word.clone());
    }
    flush(&mut current, &mut results);

    let mut paragraph_chars = 0;
    for index in 0..results.len() {
        if index == 0 {
            paragraph_chars = results[index].text.chars().count();
            continue;
        }
        let gap = results[index].start_ms - results[index - 1].end_ms;
        let next_chars = results[index].text.chars().count();
        results[index].paragraph_break_before = gap >= settings.paragraph_pause_ms
            || paragraph_chars + next_chars > settings.max_paragraph_chars;
        if results[index].paragraph_break_before {
            paragraph_chars = next_chars;
        } else {
            paragraph_chars += next_chars;
        }
    }
    results
}

#[cfg(test)]
mod tests {
    use super::*;

    fn word(text: &str, start_ms: i64, end_ms: i64) -> RecognizedWord {
        RecognizedWord {
            text: text.into(),
            start_ms,
            end_ms,
            confidence: None,
        }
    }

    #[test]
    fn adds_punctuation_and_splits_from_pauses() {
        let words = vec![
            word("今日は", 0, 300),
            word("確認します", 900, 1_300),
            word("次の話題です", 2_600, 3_200),
            word("補足します", 4_500, 5_000),
        ];
        let result = group_utterances(&words, &FormattingSettings::default());
        assert_eq!(
            result
                .iter()
                .map(|item| item.text.as_str())
                .collect::<Vec<_>>(),
            vec!["今日は、確認します。", "次の話題です。", "補足します。"]
        );
        assert_eq!(
            result
                .iter()
                .map(|item| item.paragraph_break_before)
                .collect::<Vec<_>>(),
            vec![true, false, false]
        );
    }

    #[test]
    fn creates_paragraph_after_long_pause() {
        let result = group_utterances(
            &[word("最初の文", 0, 500), word("新しい段落", 2_600, 3_200)],
            &FormattingSettings::default(),
        );
        assert!(result[1].paragraph_break_before);
    }
}
