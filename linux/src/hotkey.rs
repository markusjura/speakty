//! Watches the dictation shortcut, and Cancel while a dictation runs, by reading every keyboard in
//! /dev/input. Reading needs the `input` group or a udev ACL. It works under any compositor and sees
//! a modifier key held on its own, but it takes no key away from the app in front.
//!
//! Each keyboard gets a thread that blocks on its events; a watcher thread opens keyboards plugged
//! in later. Remappers such as kanata or keyd grab the physical keyboard and type through a virtual
//! one, which is read like any other.

use crate::shortcut::{Modifiers, Shortcut, is_modifier};
use evdev::{Device, EventSummary, KeyCode};
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Event {
    Pressed,
    Released,
    /// Another key went down while the shortcut was held, as in Super+C with Right Super.
    Interrupted,
    /// The Cancel key, while `dictating`.
    Cancel,
}

/// What the main thread tells the readers.
#[derive(Clone, Copy, Debug)]
pub struct Watch {
    pub shortcut: Shortcut,
    pub cancel: Option<Shortcut>,
    /// Cancel works only while a dictation runs.
    pub dictating: bool,
    /// Set while Settings records a new shortcut, so the current one doesn't fire.
    pub paused: bool,
}

/// The name of Speakty's own virtual keyboard, which pastes. Its keys are never the user's.
pub const PASTE_KEYBOARD_NAME: &str = "Speakty paste keyboard";

struct State {
    watch: Watch,
    held: bool,
    modifiers: Modifiers,
    last_input: Instant,
}

#[derive(Clone)]
pub struct HotkeyMonitor {
    state: Arc<Mutex<State>>,
    /// Whether any keyboard could be opened, which needs read access to /dev/input.
    readable: Arc<Mutex<Option<bool>>>,
}

impl HotkeyMonitor {
    /// Starts reading every keyboard. `events` receives the shortcut's events.
    pub fn start(watch: Watch, events: async_channel::Sender<Event>) -> Self {
        let monitor = Self {
            state: Arc::new(Mutex::new(State { watch, held: false, modifiers: Modifiers::default(), last_input: Instant::now() })),
            readable: Arc::default(),
        };
        let watcher = monitor.clone();
        std::thread::Builder::new()
            .name("keyboards".into())
            .spawn(move || watcher.watch_devices(events))
            .expect("keyboard watcher thread");
        monitor
    }

    pub fn set_watch(&self, watch: Watch) {
        let mut state = self.state.lock().unwrap();
        let changed = state.watch.shortcut != watch.shortcut || watch.paused;
        state.watch = watch;
        // A held shortcut that changes, or a pause, ends the hold silently; the dictation it started
        // ends with the next press, as a latched one does.
        if changed {
            state.held = false;
        }
    }

    /// Time since the last key on any keyboard, which tells the updater when a relaunch interrupts nothing.
    pub fn idle_time(&self) -> Duration {
        self.state.lock().unwrap().last_input.elapsed()
    }

    /// None until the first scan.
    pub fn can_read_keyboards(&self) -> Option<bool> {
        *self.readable.lock().unwrap()
    }

    fn watch_devices(&self, events: async_channel::Sender<Event>) {
        let mut inotify = inotify::Inotify::init().ok();
        if let Some(inotify) = &mut inotify {
            let _ = inotify.watches().add("/dev/input", inotify::WatchMask::CREATE | inotify::WatchMask::ATTRIB);
        }
        // Each reader removes its path when its device goes away, so a keyboard plugged in again reopens.
        let opened: Arc<Mutex<HashSet<PathBuf>>> = Arc::default();
        let mut buffer = [0; 4096];
        loop {
            let mut any_readable = false;
            let mut denied = false;
            for entry in std::fs::read_dir("/dev/input").into_iter().flatten().flatten() {
                let path = entry.path();
                if !path.file_name().is_some_and(|n| n.to_string_lossy().starts_with("event")) {
                    continue;
                }
                if opened.lock().unwrap().contains(&path) {
                    any_readable = true;
                    continue;
                }
                match Device::open(&path) {
                    Ok(device) => {
                        any_readable = true;
                        if is_keyboard(&device) {
                            opened.lock().unwrap().insert(path.clone());
                            self.read(path, device, events.clone(), opened.clone());
                        }
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::PermissionDenied => denied = true,
                    Err(_) => {}
                }
            }
            let readable = any_readable || !denied;
            if *self.readable.lock().unwrap() != Some(readable) {
                *self.readable.lock().unwrap() = Some(readable);
                if !readable {
                    log::error!("Can't read /dev/input; the shortcut needs the input group");
                }
            }
            // A new device's permissions are set by udev just after it appears, hence ATTRIB, and a
            // timeout as a fallback for missed events.
            match &mut inotify {
                Some(inotify) => {
                    let _ = inotify.read_events_blocking(&mut buffer);
                    std::thread::sleep(Duration::from_millis(200));
                }
                None => std::thread::sleep(Duration::from_secs(5)),
            }
        }
    }

    fn read(&self, path: PathBuf, mut device: Device, events: async_channel::Sender<Event>, opened: Arc<Mutex<HashSet<PathBuf>>>) {
        let monitor = self.clone();
        let name = device.name().unwrap_or("keyboard").to_string();
        log::info!("Watching {name} at {}", path.display());
        std::thread::spawn(move || {
            while let Ok(batch) = device.fetch_events() {
                for event in batch {
                    if let EventSummary::Key(_, key, value) = event.destructure() {
                        for event in monitor.handle(key, value) {
                            let _ = events.send_blocking(event);
                        }
                    }
                }
            }
            opened.lock().unwrap().remove(&path);
            log::info!("Stopped watching {name}");
        });
    }

    /// The events a key going down (1), up (0), or repeating (2) causes.
    fn handle(&self, key: KeyCode, value: i32) -> Vec<Event> {
        let mut state = self.state.lock().unwrap();
        state.last_input = Instant::now();
        if value == 2 {
            return Vec::new();
        }
        let is_down = value == 1;
        let watch = state.watch;
        let mut events = Vec::new();
        if watch.paused {
            state.modifiers.set(key, is_down);
            return events;
        }
        if key == watch.shortcut.key {
            if is_down && !state.held && state.modifiers == watch.shortcut.modifiers {
                state.held = true;
                events.push(Event::Pressed);
            } else if !is_down && state.held {
                state.held = false;
                events.push(Event::Released);
            }
            state.modifiers.set(key, is_down);
            return events;
        }
        if state.modifiers.set(key, is_down) || !is_down || is_modifier(key) {
            return events;
        }
        // Cancel acts on the dictation, so unlike other keys it doesn't interrupt a held shortcut. It
        // matches with or without the held shortcut's modifiers.
        let is_cancel = watch.cancel.is_some_and(|cancel| {
            cancel.key == key
                && (state.modifiers == cancel.modifiers || state.modifiers == cancel.modifiers.union(&watch.shortcut.held_modifiers()))
        });
        if watch.dictating && is_cancel {
            events.push(Event::Cancel);
        } else if state.held {
            state.held = false;
            events.push(Event::Interrupted);
        }
        events
    }
}

/// Keyboards, including virtual ones, but not mice, which report buttons, nor Speakty's paste keyboard.
fn is_keyboard(device: &Device) -> bool {
    device.name() != Some(PASTE_KEYBOARD_NAME)
        && device.supported_keys().is_some_and(|keys| keys.contains(KeyCode::KEY_ESC) || keys.contains(KeyCode::KEY_RIGHTMETA))
}

/// Whether Speakty can create its virtual keyboard to paste, which needs write access to /dev/uinput.
pub fn can_write_uinput() -> bool {
    std::fs::OpenOptions::new().write(true).open(Path::new("/dev/uinput")).is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn monitor(shortcut: Shortcut) -> HotkeyMonitor {
        let watch = Watch { shortcut, cancel: Some(Shortcut::key(KeyCode::KEY_ESC)), dictating: false, paused: false };
        HotkeyMonitor {
            state: Arc::new(Mutex::new(State { watch, held: false, modifiers: Modifiers::default(), last_input: Instant::now() })),
            readable: Arc::default(),
        }
    }

    #[test]
    fn a_modifier_key_alone_presses_and_releases() {
        let monitor = monitor(Shortcut::default());
        assert_eq!(monitor.handle(KeyCode::KEY_RIGHTMETA, 1), [Event::Pressed]);
        assert_eq!(monitor.handle(KeyCode::KEY_RIGHTMETA, 2), []);
        assert_eq!(monitor.handle(KeyCode::KEY_RIGHTMETA, 0), [Event::Released]);
    }

    #[test]
    fn another_key_during_a_hold_interrupts_it() {
        let monitor = monitor(Shortcut::default());
        monitor.handle(KeyCode::KEY_RIGHTMETA, 1);
        assert_eq!(monitor.handle(KeyCode::KEY_LEFTSHIFT, 1), [], "A modifier doesn't interrupt");
        assert_eq!(monitor.handle(KeyCode::KEY_C, 1), [Event::Interrupted]);
        assert_eq!(monitor.handle(KeyCode::KEY_RIGHTMETA, 0), [], "The release after an interruption is no release");
    }

    #[test]
    fn cancel_works_only_while_dictating() {
        let monitor = monitor(Shortcut::default());
        assert_eq!(monitor.handle(KeyCode::KEY_ESC, 1), []);
        monitor.state.lock().unwrap().watch.dictating = true;
        monitor.handle(KeyCode::KEY_RIGHTMETA, 1);
        assert_eq!(monitor.handle(KeyCode::KEY_ESC, 1), [Event::Cancel], "Also with the shortcut held");
    }

    #[test]
    fn a_combination_needs_its_modifiers() {
        let shortcut = Shortcut { key: KeyCode::KEY_D, modifiers: Modifiers { ctrl: true, alt: true, ..Default::default() } };
        let monitor = monitor(shortcut);
        assert_eq!(monitor.handle(KeyCode::KEY_D, 1), []);
        monitor.handle(KeyCode::KEY_D, 0);
        monitor.handle(KeyCode::KEY_LEFTCTRL, 1);
        monitor.handle(KeyCode::KEY_RIGHTALT, 1);
        assert_eq!(monitor.handle(KeyCode::KEY_D, 1), [Event::Pressed]);
        assert_eq!(monitor.handle(KeyCode::KEY_D, 0), [Event::Released]);
    }
}
