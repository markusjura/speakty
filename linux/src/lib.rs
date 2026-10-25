//! Speakty for Linux. The binary in main.rs runs the app; the library holds its parts, so the
//! integration tests in tests/ reach the pure ones.

pub mod app;
pub mod dictation;
pub mod focus;
pub mod hotkey;
pub mod identity;
pub mod install;
pub mod media;
pub mod muter;
pub mod observable;
pub mod overlay;
pub mod paste;
pub mod preferences;
pub mod recorder;
pub mod settings;
pub mod shortcut;
pub mod sounds;
pub mod transcriber;
pub mod transcript;
pub mod tray;
pub mod updater;
