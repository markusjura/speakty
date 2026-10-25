//! Mutes the default output while a dictation records, through WirePlumber's wpctl, and unmutes it
//! afterwards. The muted node is written to the state directory first, so a crash mid-dictation
//! leaves nothing muted after the next launch.

use crate::identity;
use std::process::Command;

/// Mute and restore run in order on a thread of their own, as wpctl takes a moment, so a restore
/// always follows the mute it undoes.
pub struct OutputMuter {
    commands: std::sync::mpsc::Sender<bool>,
}

impl OutputMuter {
    pub fn new() -> Self {
        let (commands, received) = std::sync::mpsc::channel::<bool>();
        std::thread::spawn(move || {
            restore();
            for mutes in received {
                if mutes { mute() } else { restore() }
            }
        });
        Self { commands }
    }

    pub fn mute(&self) {
        let _ = self.commands.send(true);
    }

    pub fn restore(&self) {
        let _ = self.commands.send(false);
    }
}

fn record() -> std::path::PathBuf {
    identity::state_dir().join("muted-output")
}

fn mute() {
    if record().exists() {
        return;
    }
    let Some(node) = default_sink() else { return };
    if wpctl(&["get-volume", &node]).is_some_and(|volume| volume.contains("[MUTED]")) {
        return;
    }
    let _ = std::fs::create_dir_all(identity::state_dir());
    if std::fs::write(record(), &node).is_ok() && wpctl(&["set-mute", &node, "1"]).is_none() {
        let _ = std::fs::remove_file(record());
    }
}

/// Keeps the record when unmuting fails, so the next stop or launch tries again.
fn restore() {
    let Ok(node) = std::fs::read_to_string(record()) else { return };
    // A node that's gone meanwhile has nothing left to unmute.
    if wpctl(&["set-mute", node.trim(), "0"]).is_some() || wpctl(&["inspect", node.trim()]).is_none() {
        let _ = std::fs::remove_file(record());
    }
}

/// The default output's node ID, which stays the same while PipeWire runs.
fn default_sink() -> Option<String> {
    let inspect = wpctl(&["inspect", "@DEFAULT_AUDIO_SINK@"])?;
    let id = inspect.lines().next()?.strip_prefix("id ")?.split(',').next()?;
    Some(id.trim().to_string())
}

fn wpctl(arguments: &[&str]) -> Option<String> {
    let output = Command::new("wpctl").args(arguments).output().ok()?;
    output.status.success().then(|| String::from_utf8_lossy(&output.stdout).into_owned())
}
