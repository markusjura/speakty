//! The single typed preference store, saved as settings.json in the config directory. Each section
//! is validated on its own: a section that fails to parse or is invalid falls back to its defaults,
//! and missing fields keep theirs, so a settings file from an older version still loads.

use crate::identity;
use crate::observable::Observable;
use crate::shortcut::Shortcut;
use crate::transcript::Replacement;
use evdev::KeyCode;
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use std::path::PathBuf;
use std::rc::Rc;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Appearance {
    #[default]
    System,
    Light,
    Dark,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct General {
    pub appearance: Appearance,
    /// Off by default: Speakty opens from the app launcher, and not every bar shows a tray.
    pub shows_tray_icon: bool,
    pub checks_for_updates: bool,
    /// Downloads updates and relaunches into them once that interrupts nothing.
    pub installs_updates: bool,
}

impl Default for General {
    fn default() -> Self {
        Self { appearance: Appearance::System, shows_tray_icon: false, checks_for_updates: true, installs_updates: true }
    }
}

/// How the dictation shortcut records.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ShortcutMode {
    /// A hold records until the release, and a tap until the next press.
    #[default]
    HoldOrTap,
    Hold,
    Tap,
}

/// How the recording display looks. Each style shows the voice level while listening and moves
/// differently while transcribing. The macOS app's Glass style needs Liquid Glass, so it reads as Dark.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum OverlayStyle {
    #[default]
    #[serde(alias = "minimal", alias = "glass")]
    Dark,
    Orb,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum OverlayPosition {
    #[default]
    Bottom,
    Top,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Recording {
    pub shortcut: Shortcut,
    pub shortcut_mode: ShortcutMode,
    /// None turns the key off. The key also reaches the app in front, since Wayland lets no app take
    /// a key from the others.
    pub cancel_shortcut: Option<Shortcut>,
    pub style: OverlayStyle,
    /// The display's size, as a multiple of the default size.
    pub scale: f64,
    pub position: OverlayPosition,
    /// Pixels between the display and the edge of the screen, inside bars such as Waybar.
    pub edge_distance: f64,
    /// The PipeWire node name of the chosen microphone; None follows the default input.
    pub microphone: Option<String>,
    /// A soft tick when dictation starts and when the text lands.
    pub plays_sounds: bool,
    pub mutes_audio: bool,
    pub pauses_media: bool,
}

impl Default for Recording {
    fn default() -> Self {
        Self {
            shortcut: Shortcut::default(),
            shortcut_mode: ShortcutMode::HoldOrTap,
            cancel_shortcut: Some(Shortcut::key(KeyCode::KEY_ESC)),
            style: OverlayStyle::Dark,
            scale: 1.0,
            position: OverlayPosition::Bottom,
            edge_distance: 24.0,
            microphone: None,
            plays_sounds: true,
            mutes_audio: true,
            pauses_media: false,
        }
    }
}

impl Recording {
    pub const EDGE_DISTANCE_RANGE: std::ops::RangeInclusive<f64> = 0.0..=120.0;
    /// Mostly larger: the default is already small, so it sits a fifth of the way along.
    pub const SCALE_RANGE: std::ops::RangeInclusive<f64> = 0.75..=2.0;

    fn is_valid(&self) -> bool {
        Self::EDGE_DISTANCE_RANGE.contains(&self.edge_distance)
            && Self::SCALE_RANGE.contains(&self.scale)
            && self.cancel_shortcut != Some(self.shortcut)
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Transcript {
    /// Names and terms recognition should lean toward, newest first.
    pub vocabulary: Vec<String>,
    /// Applied top to bottom after recognition.
    pub replacements: Vec<Replacement>,
    /// Splits a long transcript into paragraphs, separated by a blank line, and starts one where
    /// "new paragraph" is said.
    pub splits_paragraphs: bool,
    /// Leaves each pasted transcript on the clipboard instead of restoring what was there before.
    pub copies_to_clipboard: bool,
}

impl Default for Transcript {
    fn default() -> Self {
        Self { vocabulary: Vec::new(), replacements: Vec::new(), splits_paragraphs: true, copies_to_clipboard: false }
    }
}

impl Transcript {
    fn is_valid(&self) -> bool {
        self.replacements.iter().all(Replacement::is_valid)
    }
}

/// Settings for testing Speakty Dev, which only it reads. Written by hand or by scripts.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Debug {
    /// A PipeWire source to record from instead of the chosen microphone, such as the virtual one
    /// scripts/dictate.sh plays recordings into. Read at the start of every dictation.
    pub microphone: Option<String>,
    /// An update manifest to check instead of GitHub, as a URL or a path. Speakty Dev updates only from it.
    #[serde(rename = "updateFeedURL")]
    pub update_feed_url: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Preferences {
    pub general: General,
    pub recording: Recording,
    pub transcript: Transcript,
    #[serde(skip_serializing_if = "is_default")]
    pub debug: Debug,
}

fn is_default(debug: &Debug) -> bool {
    *debug == Debug::default()
}

impl Preferences {
    /// Every section valid, so a change that would break one is refused.
    pub fn is_valid(&self) -> bool {
        self.recording.is_valid() && self.transcript.is_valid()
    }

    pub fn parse(json: &str) -> Self {
        let Ok(serde_json::Value::Object(stored)) = serde_json::from_str(json) else { return Self::default() };
        fn section<T: DeserializeOwned + Default>(stored: &serde_json::Map<String, serde_json::Value>, key: &str, valid: fn(&T) -> bool) -> T {
            stored.get(key).and_then(|value| T::deserialize(value).ok()).filter(valid).unwrap_or_default()
        }
        Self {
            general: section(&stored, "general", |_| true),
            recording: section(&stored, "recording", Recording::is_valid),
            transcript: section(&stored, "transcript", Transcript::is_valid),
            debug: if identity::IS_DEV { section(&stored, "debug", |_| true) } else { Debug::default() },
        }
    }
}

/// The preferences, loaded once and saved on every accepted change.
pub struct Store {
    pub value: Rc<Observable<Preferences>>,
}

impl Store {
    pub fn path() -> PathBuf {
        identity::config_dir().join("settings.json")
    }

    pub fn load() -> Self {
        let preferences = std::fs::read_to_string(Self::path()).map(|json| Preferences::parse(&json)).unwrap_or_default();
        Self { value: Observable::new(preferences) }
    }

    pub fn get(&self) -> Preferences {
        self.value.get()
    }

    /// Applies `change` and saves it, unless it would leave a section invalid.
    pub fn update(&self, change: impl FnOnce(&mut Preferences)) {
        let mut next = self.get();
        change(&mut next);
        if !next.is_valid() || next == self.get() {
            return;
        }
        // Debug settings come from the file only, so a save keeps what a script wrote there.
        next.debug = Self::stored_debug();
        if let Err(error) = save(&next) {
            log::error!("Couldn't save the settings: {error}");
        }
        self.value.set(next);
    }

    /// The debug settings as the file has them now, so scripts can change them while Speakty Dev runs.
    pub fn stored_debug() -> Debug {
        std::fs::read_to_string(Self::path()).map(|json| Preferences::parse(&json).debug).unwrap_or_default()
    }
}

fn save(preferences: &Preferences) -> std::io::Result<()> {
    let path = Store::path();
    std::fs::create_dir_all(path.parent().unwrap())?;
    let staged = path.with_extension("json.new");
    std::fs::write(&staged, serde_json::to_string_pretty(preferences)? + "\n")?;
    std::fs::rename(staged, path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_fields_keep_their_defaults() {
        let preferences = Preferences::parse(r#"{"recording": {"scale": 1.5}, "transcript": {"vocabulary": ["Codex"]}}"#);
        assert_eq!(preferences.recording.scale, 1.5);
        assert_eq!(preferences.recording.cancel_shortcut, Some(Shortcut::key(KeyCode::KEY_ESC)));
        assert_eq!(preferences.transcript.vocabulary, ["Codex"]);
        assert!(preferences.transcript.splits_paragraphs);
    }

    #[test]
    fn an_invalid_section_falls_back_alone() {
        let preferences = Preferences::parse(r#"{"recording": {"scale": 9}, "transcript": {"vocabulary": ["Codex"]}}"#);
        assert_eq!(preferences.recording, Recording::default());
        assert_eq!(preferences.transcript.vocabulary, ["Codex"]);
    }

    #[test]
    fn a_cleared_cancel_key_stays_cleared() {
        let mut preferences = Preferences::default();
        preferences.recording.cancel_shortcut = None;
        let json = serde_json::to_string(&preferences).unwrap();
        assert_eq!(Preferences::parse(&json).recording.cancel_shortcut, None);
    }

    #[test]
    fn the_macos_style_names_load() {
        let preferences = Preferences::parse(r#"{"recording": {"style": "glass", "shortcut": {"key": "KEY_RIGHTCTRL"}}}"#);
        assert_eq!(preferences.recording.style, OverlayStyle::Dark);
        assert_eq!(preferences.recording.shortcut, Shortcut::key(KeyCode::KEY_RIGHTCTRL));
    }
}
