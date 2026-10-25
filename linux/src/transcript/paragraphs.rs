//! Smart paragraphs: a long transcript is split at the sentence boundaries that read best as
//! paragraph breaks, and a spoken "new paragraph" breaks exactly where it was said.

use super::sentences;
use regex::Regex;
use std::collections::HashSet;
use std::sync::LazyLock;

/// Below this, a transcript is a message, not a text with paragraphs, and stays one paragraph.
const MINIMUM_WORDS: usize = 50;
/// The paragraph length, in words, that costs nothing. Longer and shorter ones cost more the
/// further they're off, so a long text splits into even paragraphs instead of full ones and a stub.
const TARGET_WORDS: f64 = 50.0;

/// `text` with blank lines between paragraphs. Breaks go between sentences, where they minimize
/// the paragraphs' length costs less each break's strength. An opening that changes the topic,
/// such as "Also," or "Außerdem", strengthens a break; one that continues, such as "But" or
/// "Weil", weakens it. Line breaks already in the text, such as from "new paragraph", stay and
/// always end a paragraph. Pauses aren't used: a pause to think is as long as a pause between
/// topics, and Parakeet often ends a sentence at either.
pub fn paragraphs(text: &str) -> String {
    let sentences = sentences(text);
    let words: Vec<usize> = sentences.iter().map(|s| text[s.clone()].split_whitespace().count()).collect();
    if sentences.len() < 2 || words.iter().sum::<usize>() < MINIMUM_WORDS {
        return text.to_string();
    }
    let gaps: Vec<&str> = sentences.windows(2).map(|pair| &text[pair[0].end..pair[1].start]).collect();
    let is_kept: Vec<bool> = gaps.iter().map(|gap| gap.contains('\n')).collect();
    // strength[k] is how well gap k, before sentence k + 1, reads as a paragraph break.
    let strength: Vec<f64> = (0..gaps.len()).map(|k| opening_strength(&text[sentences[k + 1].clone()])).collect();

    // best[i] is the lowest cost of sentences 0..i, and start[i] where its last paragraph starts.
    let count = sentences.len();
    let mut best = vec![f64::INFINITY; count + 1];
    best[0] = 0.0;
    let mut start = vec![0; count + 1];
    for end in 1..=count {
        let mut length = 0;
        for first in (0..end).rev() {
            length += words[first];
            let length_cost = ((length as f64 - TARGET_WORDS) / TARGET_WORDS).powi(2);
            let break_bonus = if first > 0 && !is_kept[first - 1] { strength[first - 1] } else { 0.0 };
            let cost = best[first] + length_cost - break_bonus;
            if cost < best[end] {
                best[end] = cost;
                start[end] = first;
            }
            // A paragraph doesn't reach across a line break that's already there.
            if first > 0 && is_kept[first - 1] {
                break;
            }
        }
    }
    let mut breaks = HashSet::new();
    let mut end = count;
    while end > 0 {
        end = start[end];
        if end > 0 {
            breaks.insert(end - 1);
        }
    }

    let mut result = text[..sentences[0].start].to_string();
    for (index, sentence) in sentences.iter().enumerate() {
        result += &text[sentence.clone()];
        if index < gaps.len() {
            result += if breaks.contains(&index) && !is_kept[index] { "\n\n" } else { gaps[index] };
        }
    }
    result + &text[sentences[count - 1].end..]
}

/// 1 is the punctuation and spaces before the phrase, 2 the phrase, and 3 the punctuation after.
static COMMAND: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"([\s,.;:!?]*)\b((?i:new paragraph|neuer absatz))\b([.,;:!?]*)\s*").unwrap());

/// Replaces each spoken "new paragraph" or "neuer Absatz" with a blank line. The sentence before
/// it is ended with a period, keeping a "?" or "!" Parakeet put there, and the next one is
/// capitalized, so the command may interrupt a sentence. After a word such as "a" or "ein", as in
/// "start a new paragraph", the phrase is meant literally and stays.
pub fn applying_paragraph_commands(text: &str) -> String {
    let mut result = String::new();
    let mut rest = text.to_string();
    while let Some(captures) = COMMAND.captures(&rest) {
        let (whole, before, phrase, after) = (captures.get(0).unwrap(), &captures[1], captures.get(2).unwrap(), &captures[3]);
        let head = result.clone() + &rest[..whole.start()];
        let preceding_word = head.split_whitespace().last().map(str::to_lowercase);
        if before.chars().all(char::is_whitespace) && preceding_word.is_some_and(|w| LITERAL_PREFIXES.contains(&w.as_str())) {
            result = head + &rest[whole.start()..phrase.end()];
            rest = rest[phrase.end()..].to_string();
            continue;
        }
        // A sentence still open, also before a closing bracket or quote, gets the "?" or "!" said
        // around the command, or a period. Commas and colons go.
        let last = head.chars().rev().find(|c| !")]\"'”’“‘»«".contains(*c));
        let is_open = last.is_some_and(|c| !c.is_whitespace() && !".?!…".contains(c));
        let ending = if is_open {
            before.chars().chain(after.chars()).find(|c| "?!".contains(*c)).map_or(".".to_string(), String::from)
        } else {
            String::new()
        };
        result = head + &ending + "\n\n";
        let next = &rest[whole.end()..];
        let mut chars = next.chars();
        rest = chars.next().map(|c| c.to_uppercase().chain(chars).collect()).unwrap_or_default();
    }
    result + &rest
}

/// Words after which "new paragraph" is part of the sentence.
const LITERAL_PREFIXES: &[&str] = &[
    "a", "an", "the", "this", "that", "another", "one", "each", "every", "no", "any", "my", "your", "his", "her", "its",
    "our", "their", "ein", "kein", "mein", "dein", "sein", "ihr", "unser", "euer",
];

/// Positive for a sentence that opens a new topic, negative for one that continues the last.
fn opening_strength(sentence: &str) -> f64 {
    // Without commas, so "Okay, so" opens like "Okay so".
    let opening = sentence.to_lowercase().replace(',', "");
    let opens = |phrases: &[&str]| {
        phrases.iter().any(|phrase| {
            opening.strip_prefix(phrase).is_some_and(|rest| !rest.chars().next().is_some_and(char::is_alphabetic))
        })
    };
    if opens(TOPIC_OPENINGS) {
        0.25
    } else if opens(CONTINUING_OPENINGS) {
        -0.3
    } else {
        0.0
    }
}

const TOPIC_OPENINGS: &[&str] = &[
    "also", "anyway", "another thing", "besides", "by the way", "finally", "first", "firstly", "second", "secondly",
    "third", "thirdly", "lastly", "in addition", "in summary", "to summarize", "overall", "moving on", "next",
    "on another note", "speaking of", "okay so", "ok so", "all right", "alright", "außerdem", "zudem", "darüber hinaus",
    "übrigens", "abschließend", "zum schluss", "zusammenfassend", "insgesamt", "erstens", "zweitens", "drittens",
    "als nächstes", "ansonsten", "noch etwas", "okay also",
];

const CONTINUING_OPENINGS: &[&str] = &[
    "and", "or", "but", "because", "which", "so that", "for example", "for instance", "that means", "und", "oder",
    "aber", "weil", "denn", "sondern", "zum beispiel", "das heißt", "deshalb", "deswegen",
];
