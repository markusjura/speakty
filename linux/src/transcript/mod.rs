//! The steps between recognition and paste. Pure functions, so their rules are tested directly,
//! with the cases in spec/transcript-cases.json that the macOS app runs too.

mod paragraphs;

pub use paragraphs::{applying_paragraph_commands, paragraphs};

use fancy_regex::{Captures, Regex};
use serde::{Deserialize, Serialize};
use unicode_segmentation::UnicodeSegmentation;

pub const SAMPLE_RATE: usize = 16_000;

/// A find-and-replace rule applied to every transcript. Plain text matches whole words and ignores
/// case; a pattern is a regular expression whose replacement uses $1 for its groups.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Replacement {
    pub find: String,
    pub replacement: String,
    pub is_pattern: bool,
}

impl Replacement {
    /// None when `find` is empty or not a valid pattern.
    pub fn expression(&self) -> Option<Regex> {
        if self.find.is_empty() {
            return None;
        }
        let pattern = if self.is_pattern {
            self.find.clone()
        } else {
            // Lookarounds instead of \b, so a rule may start or end with a non-word character, as in "co-dex".
            format!(r"(?i)(?<!\w){}(?!\w)", fancy_regex::escape(&self.find))
        };
        Regex::new(&pattern).ok()
    }

    pub fn is_valid(&self) -> bool {
        self.expression().is_some()
    }
}

/// The speech in a recording: leading and trailing silence trimmed, keeping a little margin, then
/// half a second of silence appended, without which Parakeet can drop a fast final word. Empty
/// when nothing louder than room noise was recorded.
pub fn speech(samples: &[f32]) -> Vec<f32> {
    let frame = SAMPLE_RATE / 50;
    let levels: Vec<f32> = samples
        .chunks(frame)
        .map(|chunk| (chunk.iter().map(|s| s * s).sum::<f32>() / chunk.len() as f32).sqrt())
        .collect();
    let loudest = levels.iter().copied().fold(0.0, f32::max);
    let threshold = 0.004f32.max(loudest * 0.05);
    let (Some(first), Some(last)) = (
        levels.iter().position(|&l| l >= threshold),
        levels.iter().rposition(|&l| l >= threshold),
    ) else {
        return Vec::new();
    };
    if loudest < 0.01 {
        return Vec::new();
    }
    let start = first.saturating_sub(10) * frame;
    let end = samples.len().min((last + 16) * frame);
    let mut speech = samples[start..end].to_vec();
    speech.resize(speech.len() + SAMPLE_RATE / 2, 0.0);
    speech
}

pub fn applying(replacements: &[Replacement], text: &str) -> String {
    replacements.iter().fold(text.to_string(), |text, rule| {
        let Some(expression) = rule.expression() else { return text };
        expression
            .replace_all(&text, |captures: &Captures<str>| {
                if rule.is_pattern { expand(&rule.replacement, captures) } else { rule.replacement.clone() }
            })
            .into_owned()
    })
}

/// Expands a replacement template as NSRegularExpression does, so rules behave the same on macOS:
/// `$` and digits name a group, taking digits while the group exists, as in `$12` with one group
/// being group 1 and a "2". A backslash makes the next character literal, and any other `$` is literal.
fn expand(template: &str, captures: &Captures<str>) -> String {
    let mut result = String::new();
    let mut chars = template.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\\' => result.extend(chars.next()),
            '$' if chars.peek().is_some_and(char::is_ascii_digit) => {
                let mut group = chars.next().and_then(|d| d.to_digit(10)).unwrap_or(0) as usize;
                while let Some(digit) = chars.peek().and_then(|d| d.to_digit(10)) {
                    let longer = group * 10 + digit as usize;
                    if longer >= captures.len() {
                        break;
                    }
                    group = longer;
                    chars.next();
                }
                result.push_str(captures.get(group).map_or("", |m| m.as_str()));
            }
            c => result.push(c),
        }
    }
    result
}

/// Ends a transcript of several sentences with a period when the last one is left open, as Parakeet
/// does when speech stops without the voice falling. A transcript of one phrase stays open, since
/// it may be a search, a name, or the middle of a sentence.
pub fn closing(text: &str) -> String {
    match text.chars().last() {
        Some(last) if last.is_alphanumeric() && sentences(text).len() > 1 => format!("{text}."),
        _ => text.to_string(),
    }
}

/// Words that end with a period without ending a sentence. A single letter, as in "z. B." or an
/// initial, counts too.
const ABBREVIATIONS: &[&str] = &[
    "dr", "mr", "mrs", "ms", "prof", "st", "jr", "sr", "vs", "etc", "e.g", "i.e", "ca", "bzw", "usw", "nr", "str", "inkl",
    "ggf", "evtl", "vgl", "bspw", "z.b", "d.h", "u.a", "no", "approx",
];

/// The byte ranges of the sentences in `text`, without the whitespace between them. Unicode's
/// sentence rules split after every abbreviation that a capital follows, so abbreviations join
/// their sentence again, keeping "Dr. Smith" one sentence, as NLTokenizer does on macOS.
pub fn sentences(text: &str) -> Vec<std::ops::Range<usize>> {
    let mut ranges: Vec<std::ops::Range<usize>> = Vec::new();
    for (start, sentence) in text.split_sentence_bound_indices() {
        let trimmed = sentence.trim_end();
        if trimmed.trim_start().is_empty() {
            continue;
        }
        let start = start + (trimmed.len() - trimmed.trim_start().len());
        let range = start..start + trimmed.trim_start().len();
        match ranges.last_mut() {
            Some(previous) if ends_with_abbreviation(&text[previous.clone()]) => previous.end = range.end,
            _ => ranges.push(range),
        }
    }
    ranges
}

fn ends_with_abbreviation(sentence: &str) -> bool {
    let Some(word) = sentence.strip_suffix('.').and_then(|s| s.split_whitespace().last()) else { return false };
    let word = word.trim_start_matches(|c: char| !c.is_alphanumeric()).to_lowercase();
    (word.chars().count() == 1 && word.chars().all(char::is_alphabetic)) || ABBREVIATIONS.contains(&word.as_str())
}

/// Fits a transcript to the text before the caret. Mid-line it gets a leading space, unless it starts
/// with a line break, and mid-sentence a capitalized first word is lowercased, unless it's "I", an
/// acronym, or starts a name from `names`. At the start of a line, or when the text before the caret
/// is unknown, it's unchanged.
pub fn fitting(text: &str, preceding: Option<&str>, names: &[String]) -> String {
    let line = preceding.and_then(|p| p.split('\n').next_back()).unwrap_or("");
    let (Some(before), Some(first)) = (line.chars().rev().find(|c| !c.is_whitespace()), text.chars().next()) else {
        return text.to_string();
    };
    let mut result = text.to_string();
    let word: Vec<char> = text.chars().take_while(|&c| c.is_alphabetic() || c == '\'' || c == '’').collect();
    let is_plain_capitalized = first.is_uppercase()
        && word.len() > 1
        && word[1..].iter().all(|c| !c.is_uppercase())
        && !text.starts_with("I'")
        && !text.starts_with("I’")
        && !names.iter().any(|name| starts_with_name(text, name));
    if !".!?:".contains(before) && is_plain_capitalized {
        result = first.to_lowercase().chain(text.chars().skip(1)).collect();
    }
    if let Some(last) = line.chars().last()
        && !last.is_whitespace()
        && !"([{\"'“‘/".contains(last)
        && !",.;:!?)]}…".contains(first)
        && first != '\n'
    {
        result.insert(0, ' ');
    }
    result
}

/// Whether `text` starts with `name`, ignoring case, followed by a word boundary.
fn starts_with_name(text: &str, name: &str) -> bool {
    if name.is_empty() {
        return false;
    }
    let mut rest = text.chars();
    let matches = name.chars().all(|n| rest.next().is_some_and(|t| t.to_lowercase().eq(n.to_lowercase())));
    matches && rest.next().is_none_or(|c| !c.is_alphanumeric())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn speech_trims_silence_and_pads_the_end() {
        let rate = SAMPLE_RATE;
        let silence = vec![0.0005f32; rate];
        let tone: Vec<f32> = (0..rate).map(|i| (i as f32 * 0.1).sin() * 0.3).collect();
        let speech = speech(&[silence.clone(), tone, silence.clone()].concat());
        // 200 ms of lead-in, the tone, 300 ms of tail, and half a second of padding.
        let expected = rate / 5 + rate + rate * 3 / 10 + rate / 2;
        assert!(speech.len().abs_diff(expected) <= rate / 50, "{} samples", speech.len());
        assert!(speech[speech.len() - rate / 2..].iter().all(|&s| s == 0.0));
        assert!(super::speech(&silence).is_empty(), "Room noise alone is no speech");
    }

    #[test]
    fn invalid_patterns_are_rejected() {
        assert!(!Replacement { find: "(unclosed".into(), replacement: "x".into(), is_pattern: true }.is_valid());
        assert!(!Replacement::default().is_valid());
    }
}
