//! Drives Speakty for checks and reports the result as text, as Scripts/ui/speakty-ui does on macOS.
//! Run without arguments for usage. Needs the graphical session's environment, which
//! linux/scripts/remote.sh and systemd-run --user provide over SSH. Commands about windows and
//! workspaces work on Hyprland and Sway.

use evdev::uinput::VirtualDevice;
use evdev::{AttributeSet, EventType, InputEvent, KeyCode};
use gtk::prelude::*;
use std::time::Duration;

const USAGE: &str = "Usage: speakty-ui <command>
  hold <key> <seconds>   Hold a key on a virtual keyboard, as a person would, such as hold rsuper 3
  tap <key>              Press and release a key
  pad <seconds>          Open a text window in front, then print what was typed or pasted into it
  windows                List Speakty's windows, and its overlay on Hyprland, with their geometry
  front                  Print the focused window's app, and `fullscreen` when it is
  workspace [number]     Print the focused workspace, or focus another
  clipboard              Print the clipboard's text
  duration <file.wav>    Print a recording's length in seconds
Keys are evdev names such as KEY_ESC, or rsuper, lsuper, rctrl, esc.";

fn key(name: &str) -> KeyCode {
    match name {
        "rsuper" => KeyCode::KEY_RIGHTMETA,
        "lsuper" => KeyCode::KEY_LEFTMETA,
        "rctrl" => KeyCode::KEY_RIGHTCTRL,
        "esc" => KeyCode::KEY_ESC,
        other => other.parse().unwrap_or_else(|_| fail(&format!("Unknown key {other}"))),
    }
}

fn fail(message: &str) -> ! {
    eprintln!("{message}");
    std::process::exit(2)
}

/// A keyboard with every key, so Speakty treats it as one. The compositor and Speakty take a moment
/// to pick up a new device.
fn keyboard() -> VirtualDevice {
    let mut keys = AttributeSet::<KeyCode>::new();
    for code in 1..=248 {
        keys.insert(KeyCode::new(code));
    }
    let device = VirtualDevice::builder()
        .and_then(|b| b.name("Speakty test keyboard").with_keys(&keys))
        .and_then(|b| b.build())
        .unwrap_or_else(|e| fail(&format!("Can't create a virtual keyboard: {e}")));
    std::thread::sleep(Duration::from_millis(1500));
    device
}

fn press(device: &mut VirtualDevice, key: KeyCode, down: bool) {
    device.emit(&[InputEvent::new(EventType::KEY.0, key.code(), down as i32)]).unwrap_or_else(|e| fail(&e.to_string()));
}

fn pad(seconds: f64) {
    let application = gtk::Application::builder().application_id("local.markus.Speakty.pad").build();
    application.connect_activate(move |application| {
        let text = gtk::TextView::builder().wrap_mode(gtk::WrapMode::WordChar).build();
        let window = gtk::ApplicationWindow::builder().application(application).title("Speakty Pad").default_width(500).default_height(300).child(&text).build();
        window.present();
        text.grab_focus();
        let application = application.clone();
        gtk::glib::timeout_add_local_once(Duration::from_secs_f64(seconds), move || {
            let buffer = text.buffer();
            print!("{}", buffer.text(&buffer.start_iter(), &buffer.end_iter(), false));
            application.quit();
        });
    });
    application.run_with_args::<&str>(&[]);
}

/// The compositor's IPC tool and its JSON reply. Hyprland's config here is Lua, so it dispatches
/// with Lua calls rather than the classic `dispatch workspace 9`.
enum Compositor {
    Hyprland,
    Sway,
}

impl Compositor {
    fn current() -> Self {
        if std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE").is_some() {
            Self::Hyprland
        } else if std::env::var_os("SWAYSOCK").is_some() {
            Self::Sway
        } else {
            fail("This needs Hyprland or Sway.")
        }
    }

    fn query(&self, what: &str) -> serde_json::Value {
        let (tool, arguments) = match self {
            Self::Hyprland => ("hyprctl", [what, "-j"]),
            Self::Sway => ("swaymsg", ["-t", what]),
        };
        let output = std::process::Command::new(tool).args(arguments).output().unwrap_or_else(|e| fail(&e.to_string()));
        serde_json::from_slice(&output.stdout).unwrap_or_default()
    }

    fn focus_workspace(&self, number: u32) {
        let output = match self {
            Self::Hyprland => std::process::Command::new("hyprctl").args(["dispatch", &format!("hl.dsp.focus({{ workspace = {number} }})")]).output(),
            Self::Sway => std::process::Command::new("swaymsg").args(["workspace", "number", &number.to_string()]).output(),
        };
        output.unwrap_or_else(|e| fail(&e.to_string()));
    }

    fn workspace(&self) -> serde_json::Value {
        match self {
            Self::Hyprland => self.query("activeworkspace")["id"].clone(),
            Self::Sway => self.query("get_workspaces").as_array().into_iter().flatten().find(|w| w["focused"] == true).map(|w| w["num"].clone()).unwrap_or_default(),
        }
    }

    /// The focused window's app and whether it's fullscreen.
    fn front(&self) -> Option<(String, bool)> {
        match self {
            Self::Hyprland => {
                let window = self.query("activewindow");
                Some((window["class"].as_str()?.to_string(), window["fullscreen"].as_u64().is_some_and(|f| f > 0)))
            }
            Self::Sway => {
                let window = sway_windows(&self.query("get_tree")).into_iter().find(|w| w["focused"] == true)?;
                let app = window["app_id"].as_str().or(window["window_properties"]["class"].as_str()).unwrap_or_default();
                Some((app.to_string(), window["fullscreen_mode"].as_u64().is_some_and(|f| f > 0)))
            }
        }
    }
}

/// Every window in a Sway tree: the nodes with a process behind them.
fn sway_windows(node: &serde_json::Value) -> Vec<serde_json::Value> {
    let mut windows: Vec<serde_json::Value> = ["nodes", "floating_nodes"].iter().flat_map(|key| node[key].as_array().into_iter().flatten()).flat_map(sway_windows).collect();
    if node["pid"].is_u64() {
        windows.push(node.clone());
    }
    windows
}

fn main() {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let argument = |i: usize| arguments.get(i).map(String::as_str).unwrap_or_else(|| fail(USAGE));
    match arguments.first().map(String::as_str) {
        Some("hold") => {
            let (key, seconds) = (key(argument(1)), argument(2).parse::<f64>().unwrap_or_else(|_| fail(USAGE)));
            let mut device = keyboard();
            press(&mut device, key, true);
            std::thread::sleep(Duration::from_secs_f64(seconds));
            press(&mut device, key, false);
            std::thread::sleep(Duration::from_millis(300));
        }
        Some("tap") => {
            let key = key(argument(1));
            let mut device = keyboard();
            press(&mut device, key, true);
            std::thread::sleep(Duration::from_millis(60));
            press(&mut device, key, false);
            std::thread::sleep(Duration::from_millis(300));
        }
        Some("pad") => pad(argument(1).parse().unwrap_or_else(|_| fail(USAGE))),
        Some("windows") => match Compositor::current() {
            compositor @ Compositor::Hyprland => {
                for (output, monitor) in compositor.query("layers").as_object().into_iter().flatten() {
                    for level in monitor["levels"].as_object().into_iter().flat_map(|l| l.values()) {
                        for layer in level.as_array().into_iter().flatten().filter(|l| l["namespace"] == "speakty") {
                            println!("overlay on {output}: {}x{} at {},{}", layer["w"], layer["h"], layer["x"], layer["y"]);
                        }
                    }
                }
                for client in compositor.query("clients").as_array().into_iter().flatten() {
                    if client["class"].as_str().is_some_and(|c| c.starts_with("local.markus.Speakty")) {
                        println!("window {}: {} at {}", client["title"], client["size"], client["at"]);
                    }
                }
            }
            // Sway's IPC doesn't list layer surfaces, so the overlay shows only in screenshots there.
            compositor @ Compositor::Sway => {
                for window in sway_windows(&compositor.query("get_tree")) {
                    if window["app_id"].as_str().is_some_and(|c| c.starts_with("local.markus.Speakty")) {
                        let rect = &window["rect"];
                        println!("window {}: [{},{}] at [{},{}]", window["name"], rect["width"], rect["height"], rect["x"], rect["y"]);
                    }
                }
            }
        },
        Some("front") => {
            if let Some((app, fullscreen)) = Compositor::current().front() {
                println!("{app}{}", if fullscreen { " fullscreen" } else { "" });
            }
        }
        Some("workspace") => {
            let compositor = Compositor::current();
            match arguments.get(1) {
                Some(number) => compositor.focus_workspace(number.parse().unwrap_or_else(|_| fail(USAGE))),
                None => println!("{}", compositor.workspace()),
            }
        }
        Some("clipboard") => {
            use wl_clipboard_rs::paste::{ClipboardType, MimeType, Seat, get_contents};
            match get_contents(ClipboardType::Regular, Seat::Unspecified, MimeType::Text) {
                Ok((mut pipe, _)) => {
                    let mut text = String::new();
                    let _ = std::io::Read::read_to_string(&mut pipe, &mut text);
                    print!("{text}");
                }
                Err(error) => println!("({error})"),
            }
        }
        Some("duration") => {
            let reader = hound::WavReader::open(argument(1)).unwrap_or_else(|e| fail(&e.to_string()));
            println!("{:.1}", reader.duration() as f64 / reader.spec().sample_rate as f64);
        }
        _ => fail(USAGE),
    }
}
