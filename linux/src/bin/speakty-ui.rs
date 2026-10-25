//! Drives Speakty for checks and reports the result as text, as Scripts/ui/speakty-ui does on macOS.
//! Run without arguments for usage. Needs the graphical session's environment, which
//! linux/scripts/remote.sh and systemd-run --user provide over SSH.

use evdev::uinput::VirtualDevice;
use evdev::{AttributeSet, EventType, InputEvent, KeyCode};
use gtk::prelude::*;
use std::time::Duration;

const USAGE: &str = "Usage: speakty-ui <command>
  hold <key> <seconds>   Hold a key on a virtual keyboard, as a person would, such as hold rsuper 3
  tap <key>              Press and release a key
  pad <seconds>          Open a text window in front, then print what was typed or pasted into it
  windows                List Speakty's overlay and windows from Hyprland
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

fn hyprctl(what: &str) -> serde_json::Value {
    let output = std::process::Command::new("hyprctl").args([what, "-j"]).output().unwrap_or_else(|e| fail(&e.to_string()));
    serde_json::from_slice(&output.stdout).unwrap_or_default()
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
        Some("windows") => {
            for (output, monitor) in hyprctl("layers").as_object().into_iter().flatten() {
                for level in monitor["levels"].as_object().into_iter().flat_map(|l| l.values()) {
                    for layer in level.as_array().into_iter().flatten().filter(|l| l["namespace"] == "speakty") {
                        println!("overlay on {output}: {}x{} at {},{}", layer["w"], layer["h"], layer["x"], layer["y"]);
                    }
                }
            }
            for client in hyprctl("clients").as_array().into_iter().flatten() {
                if client["class"].as_str().is_some_and(|c| c.starts_with("local.markus.Speakty")) {
                    println!("window {:?}: {} at {}", client["title"], client["size"], client["at"]);
                }
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
