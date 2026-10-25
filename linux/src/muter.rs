//! Mutes the default output while a dictation records, through WirePlumber's wpctl, and unmutes it
//! afterwards. The muted node is written to the state directory first, so a crash mid-dictation
//! leaves nothing muted after the next launch.

use crate::identity;
use std::process::Command;

enum Work {
    Mute,
    Restore,
    /// Answers once everything sent before is done.
    Flush(std::sync::mpsc::SyncSender<()>),
}

/// Mute and restore run in order on a thread of their own, as wpctl takes a moment, so a restore
/// always follows the mute it undoes.
pub struct OutputMuter {
    commands: std::sync::mpsc::Sender<Work>,
}

impl OutputMuter {
    pub fn new() -> Self {
        let (commands, received) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            restore();
            for command in received {
                match command {
                    Work::Mute => mute(),
                    Work::Restore => restore(),
                    Work::Flush(done) => drop(done.send(())),
                }
            }
        });
        Self { commands }
    }

    pub fn mute(&self) {
        let _ = self.commands.send(Work::Mute);
    }

    pub fn restore(&self) {
        let _ = self.commands.send(Work::Restore);
    }

    /// Waits up to two seconds for the work sent so far, so quitting never leaves the output muted.
    pub fn flush(&self) {
        let (done, finished) = std::sync::mpsc::sync_channel(1);
        if self.commands.send(Work::Flush(done)).is_ok() {
            let _ = finished.recv_timeout(std::time::Duration::from_secs(2));
        }
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
