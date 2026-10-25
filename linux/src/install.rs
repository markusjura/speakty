//! Installs Speakty for the current user, without root, so it can update itself as Sparkle does on
//! macOS. Each version gets its own folder, and `current` and `previous` link to two of them:
//!
//!   ~/.local/share/speakty/versions/<version>/speakty
//!   ~/.local/share/speakty/current  -> versions/<version>
//!   ~/.local/share/speakty/previous -> versions/<older version>
//!
//! Switching versions renames a new link over `current`, which is atomic, so a crash never leaves a
//! half-installed Speakty. A systemd user unit starts it with the graphical session, and a desktop
//! entry lets app launchers open its Settings.

use crate::identity;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

const ICON: &[u8] = include_bytes!("../packaging/speakty.png");
const INSTALLED_ID: &str = "local.markus.Speakty";

fn versions() -> PathBuf {
    identity::data_root().join("versions")
}

fn link(name: &str) -> PathBuf {
    identity::data_root().join(name)
}

/// The installed binary that the unit and the desktop entry start.
pub fn current_binary() -> PathBuf {
    link("current").join("speakty")
}

fn linked_version(name: &str) -> Option<String> {
    let target = std::fs::read_link(link(name)).ok()?;
    Some(target.file_name()?.to_string_lossy().into_owned())
}

pub fn installed_version() -> Option<String> {
    linked_version("current")
}

/// Whether `version` is already unpacked, as after a download that waits for a relaunch.
pub fn is_staged(version: &str) -> bool {
    versions().join(version).join("speakty").exists()
}

/// Unpacks `binary` as `version`, replacing a partial earlier attempt.
pub fn stage(version: &str, binary: &[u8]) -> std::io::Result<()> {
    // An empty or truncated file would run as an empty shell script and exit without a word.
    if !binary.starts_with(b"\x7fELF") {
        return Err(std::io::Error::new(std::io::ErrorKind::InvalidData, "Not a Linux executable"));
    }
    let folder = versions().join(version);
    let partial = versions().join(format!(".{version}.partial"));
    let _ = std::fs::remove_dir_all(&partial);
    std::fs::create_dir_all(&partial)?;
    let path = partial.join("speakty");
    std::fs::write(&path, binary)?;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755))?;
    let _ = std::fs::remove_dir_all(&folder);
    std::fs::rename(partial, folder)
}

/// Points `current` at `version` and `previous` at the version it replaces, then deletes the rest.
pub fn activate(version: &str) -> std::io::Result<()> {
    if !is_staged(version) {
        return Err(std::io::Error::new(std::io::ErrorKind::NotFound, format!("{version} isn't unpacked")));
    }
    let replaced = installed_version();
    if let Some(replaced) = replaced.as_deref().filter(|r| *r != version) {
        relink("previous", replaced)?;
    }
    relink("current", version)?;
    prune();
    Ok(())
}

/// Swaps `current` and `previous`, and returns the version now current.
pub fn rollback() -> std::io::Result<String> {
    let (Some(current), Some(previous)) = (installed_version(), linked_version("previous")) else {
        return Err(std::io::Error::new(std::io::ErrorKind::NotFound, "There's no previous version"));
    };
    relink("current", &previous)?;
    relink("previous", &current)?;
    Ok(previous)
}

fn relink(name: &str, version: &str) -> std::io::Result<()> {
    let staged = link(&format!(".{name}.new"));
    let _ = std::fs::remove_file(&staged);
    std::os::unix::fs::symlink(Path::new("versions").join(version), &staged)?;
    std::fs::rename(staged, link(name))
}

fn prune() {
    let keep = [installed_version(), linked_version("previous")];
    for entry in std::fs::read_dir(versions()).into_iter().flatten().flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if !keep.iter().flatten().any(|k| *k == name) {
            let _ = std::fs::remove_dir_all(entry.path());
        }
    }
}

/// Writes the desktop entry, icon, systemd unit, and the `speakty` command in ~/.local/bin, and
/// enables the unit.
pub fn integrate() -> std::io::Result<()> {
    let data = gtk::glib::user_data_dir();
    let binary = current_binary();
    let command = gtk::glib::home_dir().join(".local/bin/speakty");
    std::fs::create_dir_all(command.parent().unwrap())?;
    let staged = command.with_file_name(".speakty.new");
    let _ = std::fs::remove_file(&staged);
    std::os::unix::fs::symlink(&binary, &staged)?;
    std::fs::rename(staged, command)?;
    let icon = data.join("icons/hicolor/512x512/apps").join(format!("{INSTALLED_ID}.png"));
    std::fs::create_dir_all(icon.parent().unwrap())?;
    std::fs::write(&icon, ICON)?;
    let desktop = data.join("applications").join(format!("{INSTALLED_ID}.desktop"));
    std::fs::create_dir_all(desktop.parent().unwrap())?;
    std::fs::write(
        &desktop,
        format!(
            "[Desktop Entry]\nType=Application\nName=Speakty\nComment=Dictation that pastes where you type\n\
             Exec={} settings\nIcon={INSTALLED_ID}\nCategories=Utility;Accessibility;\n\
             Keywords=dictation;speech;voice;transcribe;\nStartupNotify=false\n",
            binary.display()
        ),
    )?;
    let unit = gtk::glib::user_config_dir().join("systemd/user").join(identity::SERVICE);
    std::fs::create_dir_all(unit.parent().unwrap())?;
    std::fs::write(
        &unit,
        format!(
            "[Unit]\nDescription=Speakty dictation\nPartOf=graphical-session.target\nAfter=graphical-session.target\n\n\
             [Service]\nExecStart={}\nRestart=on-failure\nRestartSec=3\n\n[Install]\nWantedBy=graphical-session.target\n",
            binary.display()
        ),
    )?;
    systemctl(&["daemon-reload"])?;
    systemctl(&["enable", identity::SERVICE])
}

pub fn systemctl(arguments: &[&str]) -> std::io::Result<()> {
    let status = Command::new("systemctl").arg("--user").args(arguments).status()?;
    if status.success() { Ok(()) } else { Err(std::io::Error::other(format!("systemctl {} failed", arguments.join(" ")))) }
}

/// `speakty install`: installs this binary as the current version and restarts the service. Run
/// from an unpacked release, or by linux/scripts/install.sh.
pub fn install_self() -> std::io::Result<()> {
    if identity::IS_DEV {
        return Err(std::io::Error::other("Speakty Dev doesn't install; package a release build instead"));
    }
    let binary = std::fs::read(std::env::current_exe()?)?;
    let replaced = installed_version();
    stage(identity::VERSION, &binary)?;
    activate(identity::VERSION)?;
    integrate()?;
    systemctl(&["restart", identity::SERVICE])?;
    match replaced {
        Some(replaced) if replaced != identity::VERSION => println!("Installed Speakty {} over {replaced}.", identity::VERSION),
        _ => println!("Installed Speakty {}.", identity::VERSION),
    }
    Ok(())
}
