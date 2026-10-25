//! A shortcut: a key on its own, such as Right Super, or a key with modifiers, such as Ctrl+Alt+D.
//! Keys are evdev key codes, so they name physical keys whatever the layout.

use evdev::KeyCode;
use serde::{Deserialize, Deserializer, Serialize, Serializer};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(default)]
pub struct Modifiers {
    pub ctrl: bool,
    pub alt: bool,
    pub shift: bool,
    #[serde(rename = "super")]
    pub logo: bool,
}

impl Modifiers {
    pub fn is_empty(&self) -> bool {
        *self == Self::default()
    }

    pub fn union(&self, other: &Self) -> Self {
        Self {
            ctrl: self.ctrl || other.ctrl,
            alt: self.alt || other.alt,
            shift: self.shift || other.shift,
            logo: self.logo || other.logo,
        }
    }

    /// Records a modifier key going down or up. False when `key` is no modifier.
    pub fn set(&mut self, key: KeyCode, is_down: bool) -> bool {
        let flag = match key {
            KeyCode::KEY_LEFTCTRL | KeyCode::KEY_RIGHTCTRL => &mut self.ctrl,
            KeyCode::KEY_LEFTALT | KeyCode::KEY_RIGHTALT => &mut self.alt,
            KeyCode::KEY_LEFTSHIFT | KeyCode::KEY_RIGHTSHIFT => &mut self.shift,
            KeyCode::KEY_LEFTMETA | KeyCode::KEY_RIGHTMETA => &mut self.logo,
            _ => return false,
        };
        *flag = is_down;
        true
    }

    fn title(&self) -> String {
        [(self.ctrl, "Ctrl+"), (self.alt, "Alt+"), (self.shift, "Shift+"), (self.logo, "Super+")]
            .iter()
            .filter(|(on, _)| *on)
            .map(|(_, name)| *name)
            .collect()
    }
}

pub fn is_modifier(key: KeyCode) -> bool {
    Modifiers::default().set(key, true)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(default)]
pub struct Shortcut {
    #[serde(serialize_with = "serialize_key", deserialize_with = "deserialize_key")]
    pub key: KeyCode,
    pub modifiers: Modifiers,
}

impl Default for Shortcut {
    /// Right Super, the key in the place of the Mac's Right ⌘.
    fn default() -> Self {
        Self::key(KeyCode::KEY_RIGHTMETA)
    }
}

impl Shortcut {
    pub const fn key(key: KeyCode) -> Self {
        Self { key, modifiers: Modifiers { ctrl: false, alt: false, shift: false, logo: false } }
    }

    /// The modifiers down while the shortcut is held, which include the key when it's a modifier.
    pub fn held_modifiers(&self) -> Modifiers {
        let mut modifiers = self.modifiers;
        modifiers.set(self.key, true);
        modifiers
    }

    /// A global shortcut mustn't get in the way of typing, so a key needs a modifier, unless it's a
    /// modifier key on its own or a function key.
    pub fn works_globally(&self) -> bool {
        is_modifier(self.key) || !self.modifiers.is_empty() || (KeyCode::KEY_F1.0..=KeyCode::KEY_F24.0).contains(&self.key.0)
    }

    pub fn title(&self) -> String {
        self.modifiers.title() + &key_title(self.key)
    }
}

/// The key's name as keyboards label it, such as "Right Super" or "Esc".
pub fn key_title(key: KeyCode) -> String {
    let named = match key {
        KeyCode::KEY_RIGHTMETA => "Right Super",
        KeyCode::KEY_LEFTMETA => "Left Super",
        KeyCode::KEY_RIGHTCTRL => "Right Ctrl",
        KeyCode::KEY_LEFTCTRL => "Left Ctrl",
        KeyCode::KEY_RIGHTALT => "Right Alt",
        KeyCode::KEY_LEFTALT => "Left Alt",
        KeyCode::KEY_RIGHTSHIFT => "Right Shift",
        KeyCode::KEY_LEFTSHIFT => "Left Shift",
        KeyCode::KEY_ESC => "Esc",
        KeyCode::KEY_ENTER => "Return",
        KeyCode::KEY_SPACE => "Space",
        KeyCode::KEY_CAPSLOCK => "Caps Lock",
        _ => "",
    };
    if !named.is_empty() {
        return named.to_string();
    }
    let raw = format!("{key:?}");
    let name = raw.strip_prefix("KEY_").unwrap_or(&raw);
    let mut chars = name.chars();
    chars.next().map(|c| c.to_string() + &chars.as_str().to_lowercase()).unwrap_or_default()
}

/// Keys are stored by name, such as "KEY_RIGHTMETA", which reads better than a number.
fn serialize_key<S: Serializer>(key: &KeyCode, serializer: S) -> Result<S::Ok, S::Error> {
    serializer.serialize_str(&format!("{key:?}"))
}

fn deserialize_key<'de, D: Deserializer<'de>>(deserializer: D) -> Result<KeyCode, D::Error> {
    let name = String::deserialize(deserializer)?;
    name.parse().map_err(|_| serde::de::Error::custom(format!("unknown key {name}")))
}
