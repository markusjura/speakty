//! Runs the cases in spec/transcript-cases.json, which the macOS app's tests run too.

use serde::Deserialize;
use speakty::transcript::{self, Replacement};

#[derive(Deserialize)]
struct Case {
    name: Option<String>,
    input: String,
    output: String,
}

#[derive(Deserialize)]
struct ReplacementCase {
    name: Option<String>,
    rules: Vec<Replacement>,
    input: String,
    output: String,
}

#[derive(Deserialize)]
struct FittingCase {
    name: Option<String>,
    text: String,
    before: Option<String>,
    output: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Spec {
    replacements: Vec<ReplacementCase>,
    fitting: Vec<FittingCase>,
    fitting_names: Vec<String>,
    closing: Vec<Case>,
    paragraph_commands: Vec<Case>,
    paragraphs: Vec<Case>,
}

fn spec() -> Spec {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../spec/transcript-cases.json");
    serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
}

/// Runs every case before failing, so one run shows all differences.
fn check(cases: impl IntoIterator<Item = (Option<String>, String, String)>) {
    let failures: Vec<String> = cases
        .into_iter()
        .filter(|(_, actual, expected)| actual != expected)
        .map(|(name, actual, expected)| format!("{}:\n  got      {actual:?}\n  expected {expected:?}", name.unwrap_or_default()))
        .collect();
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

fn cases(cases: Vec<Case>, apply: impl Fn(&str) -> String) -> Vec<(Option<String>, String, String)> {
    cases.into_iter().map(|c| (c.name.or(Some(c.input.clone())), apply(&c.input), c.output)).collect()
}

#[test]
fn replacements() {
    check(spec().replacements.into_iter().map(|c| (c.name, transcript::applying(&c.rules, &c.input), c.output)));
}

#[test]
fn fitting() {
    let spec = spec();
    check(spec.fitting.into_iter().map(|c| {
        (c.name.or(Some(c.text.clone())), transcript::fitting(&c.text, c.before.as_deref(), &spec.fitting_names), c.output)
    }));
}

#[test]
fn closing() {
    check(cases(spec().closing, transcript::closing));
}

#[test]
fn paragraph_commands() {
    check(cases(spec().paragraph_commands, transcript::applying_paragraph_commands));
}

#[test]
fn paragraphs() {
    check(cases(spec().paragraphs, transcript::paragraphs));
}
