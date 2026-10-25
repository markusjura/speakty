//! Pauses the media that's playing, such as music or a video, while a dictation records, and plays
//! it again afterwards, through the players' MPRIS interfaces on the session bus. Media that was
//! already paused stays paused.

use gtk::gio;
use gtk::glib::Variant;

const PLAYER: &str = "org.mpris.MediaPlayer2.Player";

/// Pause and resume run in order on a thread of their own, since asking every player takes a
/// moment, so a resume always follows the pause it undoes.
pub struct MediaPauser {
    commands: std::sync::mpsc::Sender<bool>,
}

impl MediaPauser {
    pub fn new() -> Self {
        let (commands, received) = std::sync::mpsc::channel::<bool>();
        std::thread::spawn(move || {
            // The players Speakty paused, to play again.
            let mut paused: Vec<String> = Vec::new();
            for pauses in received {
                if pauses {
                    let players = pause_playing();
                    if !players.is_empty() {
                        log::info!("Paused {}", players.join(", "));
                    }
                    paused.extend(players);
                } else {
                    for player in paused.drain(..) {
                        call(&player, "Play");
                    }
                }
            }
        });
        Self { commands }
    }

    pub fn pause(&self) {
        let _ = self.commands.send(true);
    }

    pub fn resume(&self) {
        let _ = self.commands.send(false);
    }
}

fn bus() -> Option<gio::DBusConnection> {
    gio::bus_get_sync(gio::BusType::Session, gio::Cancellable::NONE).ok()
}

/// Pauses every player that's playing and returns their bus names.
fn pause_playing() -> Vec<String> {
    let Some(bus) = bus() else { return Vec::new() };
    let names = bus
        .call_sync(Some("org.freedesktop.DBus"), "/org/freedesktop/DBus", "org.freedesktop.DBus", "ListNames", None, None,
            gio::DBusCallFlags::NONE, 500, gio::Cancellable::NONE)
        .ok()
        .and_then(|reply| reply.child_value(0).get::<Vec<String>>())
        .unwrap_or_default();
    names
        .into_iter()
        .filter(|name| name.starts_with("org.mpris.MediaPlayer2."))
        .filter(|name| {
            let status = bus.call_sync(Some(name), "/org/mpris/MediaPlayer2", "org.freedesktop.DBus.Properties", "Get",
                Some(&(PLAYER, "PlaybackStatus").into()), None, gio::DBusCallFlags::NONE, 300, gio::Cancellable::NONE);
            let playing = status.ok().and_then(|reply| reply.child_value(0).as_variant()).and_then(|v| v.get::<String>())
                .is_some_and(|status| status == "Playing");
            playing && call(name, "Pause")
        })
        .collect()
}

fn call(player: &str, method: &str) -> bool {
    bus().is_some_and(|bus| {
        bus.call_sync(Some(player), "/org/mpris/MediaPlayer2", PLAYER, method, None::<&Variant>, None,
            gio::DBusCallFlags::NONE, 500, gio::Cancellable::NONE).is_ok()
    })
}
