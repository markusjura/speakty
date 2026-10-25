//! Keeps Speakty current without alerts it didn't ask for, as Sparkle does on macOS.
//!
//! Each GitHub release v<version> carries both apps. The Linux updater reads speakty-linux.json from
//! the latest release, as Sparkle reads appcast.xml: a manifest that names the archive and its EdDSA
//! signature. The signature comes from Sparkle's key, so the macOS and Linux apps trust the same publisher. With automatic install on, the default, a newer version
//! downloads in the background and Speakty relaunches into it once that interrupts nothing: no
//! dictation runs and no key was pressed for `QUIET_PERIOD`. With it off, Settings shows the update.

use crate::identity;
use crate::install;
use crate::observable::Observable;
use crate::preferences::Store;
use base64::Engine;
use gtk::glib;
use serde::Deserialize;
use std::cell::RefCell;
use std::io::Read;
use std::rc::Rc;
use std::time::{Duration, SystemTime};

/// Sparkle's public key, SUPublicEDKey in macos/Config/Info.plist.
const PUBLIC_KEY: &str = "zfNAovkUOEVGX+Fw//AkIqkZFZBY4hOVS2btsUX9KuA=";
const MANIFEST_URL: &str = "https://github.com/markusjura/speakty/releases/latest/download/speakty-linux.json";
const CHECK_INTERVAL: Duration = Duration::from_secs(24 * 60 * 60);
/// How long the keyboards have to be quiet before Speakty relaunches into an update.
const QUIET_PERIOD: Duration = Duration::from_secs(10 * 60);

/// What a release publishes for the updater.
#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Manifest {
    pub version: String,
    pub url: String,
    pub length: u64,
    /// Base64 EdDSA signature of the archive, from Sparkle's sign_update.
    pub signature: String,
    pub notes_url: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Status {
    /// Nothing newer is known. `last_checked` says how current that is.
    Idle,
    /// Check Now is waiting for the feed.
    Checking,
    /// Check Now failed. Scheduled checks fail silently and stay idle.
    Failed(String),
    Downloading(Manifest),
    /// An update that Speakty doesn't install by itself.
    Available(Manifest),
    /// Downloaded and installed on the next relaunch.
    Ready(Manifest),
}

pub struct Updater {
    pub status: Rc<Observable<Status>>,
    pub last_checked: Rc<Observable<Option<SystemTime>>>,
    preferences: Rc<Store>,
    is_busy: Box<dyn Fn() -> bool>,
    idle_time: Box<dyn Fn() -> Duration>,
    checking: RefCell<bool>,
}

impl Updater {
    pub fn new(preferences: Rc<Store>, is_busy: impl Fn() -> bool + 'static, idle_time: impl Fn() -> Duration + 'static) -> Rc<Self> {
        Rc::new(Self {
            status: Observable::new(Status::Idle),
            last_checked: Observable::new(read_last_checked()),
            preferences,
            is_busy: Box::new(is_busy),
            idle_time: Box::new(idle_time),
            checking: RefCell::new(false),
        })
    }

    /// False in Speakty Dev unless a test feed is set, so development builds never replace themselves
    /// by accident.
    pub fn is_running(&self) -> bool {
        !identity::IS_DEV || Store::stored_debug().update_feed_url.is_some()
    }

    /// Checks on schedule and relaunches into a downloaded update when idle.
    pub fn start(self: &Rc<Self>) {
        let this = self.clone();
        glib::timeout_add_seconds_local(60, move || {
            this.tick();
            glib::ControlFlow::Continue
        });
        let this = self.clone();
        // Not at once: the first minutes after login are busy enough.
        glib::timeout_add_seconds_local_once(90, move || this.tick());
    }

    fn tick(self: &Rc<Self>) {
        if !self.is_running() {
            return;
        }
        if let Status::Ready(manifest) = self.status.get() {
            if self.preferences.get().general.installs_updates && !(self.is_busy)() && (self.idle_time)() >= QUIET_PERIOD {
                self.relaunch_into(&manifest.version);
            }
            return;
        }
        let due = self.last_checked.get().is_none_or(|last| last.elapsed().unwrap_or(CHECK_INTERVAL) >= CHECK_INTERVAL);
        if due && self.preferences.get().general.checks_for_updates {
            self.check(false, false);
        }
    }

    /// Checks now, as a scheduled check does, but reports a failure. With `relaunch`, as from
    /// `speakty update`, a newer version installs and relaunches at once.
    pub fn check_now(self: &Rc<Self>, relaunch: bool) {
        self.status.set(Status::Checking);
        self.check(true, relaunch);
    }

    fn check(self: &Rc<Self>, manually: bool, relaunch: bool) {
        if self.checking.replace(true) {
            return;
        }
        let feed = Store::stored_debug().update_feed_url;
        let installs = self.preferences.get().general.installs_updates;
        let this = self.clone();
        glib::spawn_future_local(async move {
            let found = gtk::gio::spawn_blocking(move || newest(feed.as_deref())).await.unwrap_or_else(|_| Err("The check crashed".into()));
            let now = SystemTime::now();
            this.last_checked.set(Some(now));
            write_last_checked(now);
            match found {
                Ok(Some(manifest)) if installs || relaunch => this.download(manifest, relaunch).await,
                Ok(Some(manifest)) => this.status.set(Status::Available(manifest)),
                Ok(None) => {
                    log::info!("Speakty {} is current", identity::VERSION);
                    this.status.set(Status::Idle);
                }
                Err(error) => {
                    log::info!("Update check failed: {error}");
                    this.status.set(if manually { Status::Failed(error) } else { Status::Idle });
                }
            }
            this.checking.replace(false);
        });
    }

    /// Downloads and unpacks `manifest`'s version, then relaunches into it now or when idle.
    async fn download(self: &Rc<Self>, manifest: Manifest, relaunch_now: bool) {
        self.status.set(Status::Downloading(manifest.clone()));
        let fetched = manifest.clone();
        let result = gtk::gio::spawn_blocking(move || fetch_and_stage(&fetched)).await.unwrap_or_else(|_| Err("The download crashed".into()));
        match result {
            Ok(()) => {
                log::info!("Downloaded Speakty {}", manifest.version);
                self.status.set(Status::Ready(manifest.clone()));
                if relaunch_now {
                    self.relaunch_into(&manifest.version);
                }
            }
            Err(error) => {
                log::error!("Couldn't download Speakty {}: {error}", manifest.version);
                self.status.set(Status::Failed(error));
            }
        }
    }

    /// Settings' Install button, for an update Speakty doesn't install by itself.
    pub fn install_available(self: &Rc<Self>) {
        match self.status.get() {
            Status::Available(manifest) => {
                let this = self.clone();
                glib::spawn_future_local(async move { this.download(manifest, true).await });
            }
            Status::Ready(manifest) => self.relaunch_into(&manifest.version),
            _ => {}
        }
    }

    /// Makes `version` current and replaces this process with it, keeping its PID for systemd.
    fn relaunch_into(&self, version: &str) {
        if let Err(error) = install::activate(version) {
            return log::error!("Couldn't switch to Speakty {version}: {error}");
        }
        log::info!("Relaunching into Speakty {version}");
        let error = std::os::unix::process::CommandExt::exec(&mut std::process::Command::new(install::current_binary()));
        log::error!("Couldn't relaunch: {error}");
    }
}

fn last_checked_path() -> std::path::PathBuf {
    identity::state_dir().join("last-update-check")
}

fn read_last_checked() -> Option<SystemTime> {
    let seconds: u64 = std::fs::read_to_string(last_checked_path()).ok()?.trim().parse().ok()?;
    Some(SystemTime::UNIX_EPOCH + Duration::from_secs(seconds))
}

fn write_last_checked(time: SystemTime) {
    let seconds = time.duration_since(SystemTime::UNIX_EPOCH).unwrap_or_default().as_secs();
    let _ = std::fs::create_dir_all(identity::state_dir());
    let _ = std::fs::write(last_checked_path(), seconds.to_string());
}

/// The latest release's manifest when it's newer than this build.
fn newest(feed: Option<&str>) -> Result<Option<Manifest>, String> {
    let manifest: Manifest = serde_json::from_slice(&get(feed.unwrap_or(MANIFEST_URL))?).map_err(|e| e.to_string())?;
    Ok(is_newer(&manifest.version, identity::VERSION).then_some(manifest))
}

/// Whether `version` comes after `current`. A build between releases, such as 0.2.0+dev.gabc1234,
/// comes after the release it's based on and before the next.
pub fn is_newer(version: &str, current: &str) -> bool {
    match (semver::Version::parse(version), semver::Version::parse(current)) {
        (Ok(version), Ok(current)) => version > current,
        _ => false,
    }
}

/// A URL's body, or a file's contents for a path, which test feeds use.
fn get(location: &str) -> Result<Vec<u8>, String> {
    if let Some(path) = location.strip_prefix("file://").or(location.starts_with('/').then_some(location)) {
        return std::fs::read(path).map_err(|e| format!("{path}: {e}"));
    }
    let response = ureq::get(location)
        .header("User-Agent", "Speakty")
        .call()
        .map_err(|e| e.to_string())?;
    let mut bytes = Vec::new();
    response.into_body().into_reader().take(1 << 30).read_to_end(&mut bytes).map_err(|e| e.to_string())?;
    Ok(bytes)
}

fn fetch_and_stage(manifest: &Manifest) -> Result<(), String> {
    if install::is_staged(&manifest.version) {
        return Ok(());
    }
    let archive = get(&manifest.url)?;
    verify(&archive, manifest)?;
    let mut entries = tar::Archive::new(flate2::read::GzDecoder::new(archive.as_slice()));
    for entry in entries.entries().map_err(|e| e.to_string())? {
        let mut entry = entry.map_err(|e| e.to_string())?;
        // The archive also holds the speakty/ folder, whose name matches too.
        let is_binary = entry.header().entry_type().is_file() && entry.path().is_ok_and(|p| p == std::path::Path::new("speakty/speakty"));
        if is_binary {
            let mut binary = Vec::new();
            entry.read_to_end(&mut binary).map_err(|e| e.to_string())?;
            return install::stage(&manifest.version, &binary).map_err(|e| e.to_string());
        }
    }
    Err("The archive has no speakty binary".into())
}

/// Accepts only an archive of the manifest's length, signed with Sparkle's key.
fn verify(archive: &[u8], manifest: &Manifest) -> Result<(), String> {
    if archive.len() as u64 != manifest.length {
        return Err(format!("The archive is {} bytes, not {}", archive.len(), manifest.length));
    }
    let engine = base64::engine::general_purpose::STANDARD;
    let key: [u8; 32] = engine.decode(PUBLIC_KEY).ok().and_then(|k| k.try_into().ok()).ok_or("Invalid public key")?;
    let signature: [u8; 64] = engine.decode(&manifest.signature).ok().and_then(|s| s.try_into().ok()).ok_or("Invalid signature")?;
    let key = ed25519_dalek::VerifyingKey::from_bytes(&key).map_err(|e| e.to_string())?;
    key.verify_strict(archive, &ed25519_dalek::Signature::from_bytes(&signature)).map_err(|_| "The archive's signature doesn't match".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builds_between_releases_sort_after_their_release() {
        assert!(!is_newer("0.2.0", "0.2.0+dev.gabc1234"));
        assert!(is_newer("0.2.1", "0.2.0+dev.gabc1234"));
        assert!(is_newer("0.2.0", "0.1.0-dev.gabc1234"));
        assert!(is_newer("0.2.0", "0.1.9"));
        assert!(!is_newer("0.1.0", "0.1.0"));
        assert!(!is_newer("garbage", "0.1.0"));
    }

    #[test]
    fn the_key_is_sparkles() {
        let plist = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../macos/Config/Info.plist")).unwrap();
        assert!(plist.contains(PUBLIC_KEY), "PUBLIC_KEY differs from SUPublicEDKey");
    }

    #[test]
    fn verification_rejects_a_changed_archive() {
        let manifest = Manifest { version: "1.0.0".into(), url: String::new(), length: 3, signature: "A".repeat(88), notes_url: None };
        assert!(verify(b"abc", &manifest).is_err());
        assert!(verify(b"abcd", &manifest).unwrap_err().contains("bytes"));
    }
}
