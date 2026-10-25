//! Which build this is and where it keeps its files. Debug builds are Speakty Dev, with their own
//! app ID, settings, and state, so development never touches the installed Speakty's settings.
//! Both share the downloaded models and the install root.

use std::path::PathBuf;

pub const IS_DEV: bool = cfg!(debug_assertions);
pub const APP_ID: &str = if IS_DEV { "local.markus.Speakty.dev" } else { "local.markus.Speakty" };
pub const NAME: &str = if IS_DEV { "Speakty Dev" } else { "Speakty" };
pub const VERSION: &str = env!("SPEAKTY_VERSION");
/// The systemd user unit that runs the installed Speakty.
pub const SERVICE: &str = "speakty.service";

fn folder() -> &'static str {
    if IS_DEV { "speakty-dev" } else { "speakty" }
}

/// settings.json lives here.
pub fn config_dir() -> PathBuf {
    gtk::glib::user_config_dir().join(folder())
}

/// Small state that outlives a run, such as a muted output to restore after a crash.
pub fn state_dir() -> PathBuf {
    gtk::glib::user_state_dir().join(folder())
}

/// Installed versions, the `current` and `previous` links, and the models.
pub fn data_root() -> PathBuf {
    gtk::glib::user_data_dir().join("speakty")
}

pub fn models_dir() -> PathBuf {
    data_root().join("models")
}
