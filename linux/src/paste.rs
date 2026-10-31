//! Puts a transcript where the user is typing: on the clipboard, then Ctrl+V from a virtual
//! keyboard, and Return when sending, then the previous clipboard back unless the transcript should
//! stay there.
//!
//! The clipboard goes through the Wayland data-control protocol, which Hyprland, Sway, KDE, and
//! other wlroots compositors offer. Every transcript that gets restored over carries KDE's password
//! manager hint, which clipboard histories such as cliphist (through wl-paste --watch) and Klipper
//! skip, as nspasteboard.org's transient type does on macOS. The terminals below paste with
//! Ctrl+Shift+V; the app in front is known from Hyprland, and elsewhere Ctrl+V is used.
//!
//! Without write access to /dev/uinput there's no virtual keyboard, so the transcript stays on the
//! clipboard, unmarked, to paste by hand.

use crate::hotkey::PASTE_KEYBOARD_NAME;
use evdev::uinput::VirtualDevice;
use evdev::{AttributeSet, EventType, InputEvent, KeyCode};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use wl_clipboard_rs::{copy, paste};

const SENSITIVE_TYPE: &str = "x-kde-passwordManagerHint";
/// Targets X11 apps offer through Xwayland that describe the selection rather than hold it.
const META_TYPES: &[&str] = &["TARGETS", "MULTIPLE", "SAVE_TARGETS", "TIMESTAMP", "DELETE", SENSITIVE_TYPE];
/// Speakty's own marker types, which a restore leaves out.
const MARKER_PREFIX: &str = "application/x-speakty-copy-";
/// Window classes of terminals, which paste with Ctrl+Shift+V. Compared in lowercase.
const TERMINALS: &[&str] = &[
    "kitty", "alacritty", "foot", "footclient", "org.wezfurlong.wezterm", "com.mitchellh.ghostty", "ghostty",
    "org.gnome.console", "org.gnome.terminal", "gnome-terminal-server", "org.gnome.ptyxis", "org.kde.konsole", "konsole",
    "xterm", "urxvt", "terminator", "tilix", "com.raggesilver.blackbox", "io.elementary.terminal", "st-256color",
    "dev.warp.warp",
];

type Contents = Vec<(String, Vec<u8>)>;

/// Text under every name apps ask for it by. Terminals such as kitty ask for plain text/plain.
fn text_contents(text: &str) -> Contents {
    ["text/plain;charset=utf-8", "text/plain", "UTF8_STRING", "STRING", "TEXT"]
        .iter()
        .map(|mime| (mime.to_string(), text.as_bytes().to_vec()))
        .collect()
}

/// The clipboard from before the last transcript while it waits to be restored. A transcript
/// pasted meanwhile keeps it, so a quick second dictation doesn't restore the first transcript.
struct Pending {
    saved: Contents,
    /// True while Speakty's transcript is still the clipboard.
    is_current: Arc<AtomicBool>,
    generation: u64,
}

#[derive(Default)]
struct State {
    keyboard: Option<VirtualDevice>,
    pending: Option<Pending>,
    generation: u64,
}

#[derive(Clone)]
pub struct Paster {
    state: Arc<Mutex<State>>,
}

impl Paster {
    /// Creates the virtual keyboard now, since the compositor takes a moment to pick up a new device.
    pub fn new() -> Self {
        let keyboard = virtual_keyboard().map_err(|e| log::warn!("No virtual keyboard to paste with: {e}")).ok();
        Self { state: Arc::new(Mutex::new(State { keyboard, ..Default::default() })) }
    }

    pub fn can_paste(&self) -> bool {
        self.state.lock().unwrap().keyboard.is_some()
    }

    /// Pastes `text` on a thread of its own, since reading the clipboard can wait on another app.
    /// `keeps_on_clipboard` leaves it on the clipboard as an ordinary copy, which clipboard histories
    /// record, instead of restoring what was there before.
    pub fn insert(&self, text: String, pressing_return: bool, keeps_on_clipboard: bool) {
        let state = self.state.clone();
        std::thread::spawn(move || insert(&state, text, pressing_return, keeps_on_clipboard));
    }
}

fn insert(state: &Arc<Mutex<State>>, text: String, pressing_return: bool, keeps_on_clipboard: bool) {
    let mut locked = state.lock().unwrap();
    if locked.keyboard.is_none() {
        if serve(text_contents(&text), false).is_some() {
            log::info!("Copied the transcript; pasting needs write access to /dev/uinput");
        }
        return;
    }
    let saved = match locked.pending.take() {
        _ if keeps_on_clipboard => None,
        Some(pending) if pending.is_current.load(Ordering::SeqCst) => Some(pending.saved),
        _ => Some(read_clipboard()),
    };
    locked.generation += 1;
    let generation = locked.generation;
    // Pasting now would put what the clipboard still holds into the text instead.
    let Some(is_current) = serve(text_contents(&text), saved.is_some()) else { return };
    let terminal = crate::focus::focused_class().is_some_and(|class| TERMINALS.contains(&class.to_lowercase().as_str()));
    let keyboard = locked.keyboard.as_mut().unwrap();
    let mut keys = vec![KeyCode::KEY_LEFTCTRL];
    if terminal {
        keys.push(KeyCode::KEY_LEFTSHIFT);
    }
    // KEY_V is where V sits on QWERTY and QWERTZ layouts alike.
    keys.push(KeyCode::KEY_V);
    if let Err(error) = chord(keyboard, &keys).and_then(|()| if pressing_return { chord(keyboard, &[KeyCode::KEY_ENTER]) } else { Ok(()) }) {
        log::error!("Couldn't press the paste keys: {error}");
    }
    log::info!("Pasted the transcript{}", if terminal { " into a terminal" } else { "" });
    let Some(saved) = saved else { return };
    locked.pending = Some(Pending { saved, is_current: is_current.clone(), generation });
    drop(locked);

    // The app reads the clipboard after it handles the keys, which can take a moment.
    std::thread::sleep(Duration::from_millis(400));
    let mut locked = state.lock().unwrap();
    let is_ours = locked.pending.as_ref().is_some_and(|p| p.generation == generation);
    if !is_ours || !is_current.load(Ordering::SeqCst) {
        return;
    }
    // Still holding the lock, so a dictation that pastes next reads the restored clipboard.
    let saved = locked.pending.take().unwrap().saved;
    if saved.is_empty() {
        let _ = copy::clear(copy::ClipboardType::Regular, copy::Seat::All);
    } else {
        serve(saved, true);
    }
}

/// Presses the keys in order, then releases them in reverse.
fn chord(keyboard: &mut VirtualDevice, keys: &[KeyCode]) -> std::io::Result<()> {
    for key in keys {
        keyboard.emit(&[InputEvent::new(EventType::KEY.0, key.code(), 1)])?;
        std::thread::sleep(Duration::from_millis(8));
    }
    for key in keys.iter().rev() {
        keyboard.emit(&[InputEvent::new(EventType::KEY.0, key.code(), 0)])?;
        std::thread::sleep(Duration::from_millis(8));
    }
    Ok(())
}

fn virtual_keyboard() -> std::io::Result<VirtualDevice> {
    let mut keys = AttributeSet::<KeyCode>::new();
    for key in [KeyCode::KEY_LEFTCTRL, KeyCode::KEY_LEFTSHIFT, KeyCode::KEY_V, KeyCode::KEY_ENTER] {
        keys.insert(key);
    }
    VirtualDevice::builder()?.name(PASTE_KEYBOARD_NAME).with_keys(&keys)?.build()
}

/// Makes `contents` the clipboard and serves it from a thread until another copy replaces it. Returns
/// once the clipboard shows it, with a flag that turns false when it's replaced, or None when it
/// couldn't be set within half a second.
fn serve(mut contents: Contents, sensitive: bool) -> Option<Arc<AtomicBool>> {
    // A type no one else offers, which tells when the compositor has published this copy.
    static COPIES: AtomicU64 = AtomicU64::new(0);
    let marker = format!("application/x-speakty-copy-{}-{}", std::process::id(), COPIES.fetch_add(1, Ordering::SeqCst));
    contents.push((marker.clone(), Vec::new()));
    if sensitive {
        contents.push((SENSITIVE_TYPE.into(), b"secret".to_vec()));
    }
    let is_current = Arc::new(AtomicBool::new(true));
    let flag = is_current.clone();
    std::thread::spawn(move || {
        let sources = contents
            .into_iter()
            .map(|(mime, bytes)| copy::MimeSource { source: copy::Source::Bytes(bytes.into()), mime_type: copy::MimeType::Specific(mime) })
            .collect();
        let mut options = copy::Options::new();
        options.foreground(true);
        if let Err(error) = options.copy_multi(sources) {
            log::error!("Couldn't set the clipboard: {error}");
        }
        flag.store(false, Ordering::SeqCst);
    });
    for _ in 0..50 {
        let types = paste::get_mime_types(paste::ClipboardType::Regular, paste::Seat::Unspecified);
        if types.is_ok_and(|types| types.contains(&marker)) {
            return Some(is_current);
        }
        if !is_current.load(Ordering::SeqCst) {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    log::error!("The clipboard didn't take the copy");
    None
}

/// Every type of the current clipboard with its data. Empty when the clipboard is, or when its
/// owner doesn't answer within half a second.
fn read_clipboard() -> Contents {
    let (sender, receiver) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let contents = (|| -> Result<Contents, paste::Error> {
            let types = paste::get_mime_types(paste::ClipboardType::Regular, paste::Seat::Unspecified)?;
            let mut contents = Vec::new();
            for mime in types.into_iter().filter(|t| !META_TYPES.contains(&t.as_str()) && !t.starts_with(MARKER_PREFIX)) {
                let (mut pipe, _) = paste::get_contents(paste::ClipboardType::Regular, paste::Seat::Unspecified, paste::MimeType::Specific(&mime))?;
                let mut bytes = Vec::new();
                if std::io::Read::read_to_end(&mut pipe, &mut bytes).is_ok() {
                    contents.push((mime, bytes));
                }
            }
            Ok(contents)
        })();
        let _ = sender.send(contents);
    });
    match receiver.recv_timeout(Duration::from_millis(500)) {
        Ok(Ok(contents)) => contents,
        Ok(Err(paste::Error::ClipboardEmpty | paste::Error::NoMimeType)) => Vec::new(),
        Ok(Err(error)) => {
            log::warn!("Couldn't read the clipboard to restore it: {error}");
            Vec::new()
        }
        Err(_) => {
            log::warn!("The clipboard's owner didn't answer, so it won't be restored");
            Vec::new()
        }
    }
}
