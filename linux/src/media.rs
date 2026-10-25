//! Pauses the media that's playing, such as music or a video, while a dictation records, and plays
//! it again afterwards, through the players' MPRIS interfaces on the session bus. Media that was
//! already paused stays paused.

use gtk::gio;
use gtk::glib::{self, Variant};
use std::cell::RefCell;
use std::rc::Rc;

const PLAYER: &str = "org.mpris.MediaPlayer2.Player";

#[derive(Default)]
pub struct MediaPauser {
    /// The players Speakty paused, to play again.
    paused: Rc<RefCell<Vec<String>>>,
    pausing: RefCell<Option<glib::JoinHandle<()>>>,
}

impl MediaPauser {
    pub fn pause(&self) {
        let paused = self.paused.clone();
        *self.pausing.borrow_mut() = Some(glib::spawn_future_local(async move {
            let players = gio::spawn_blocking(pause_playing).await.unwrap_or_default();
            if !players.is_empty() {
                log::info!("Paused {}", players.join(", "));
            }
            paused.borrow_mut().extend(players);
        }));
    }

    /// Also stops a pause that's still asking what plays.
    pub fn resume(&self) {
        if let Some(pausing) = self.pausing.borrow_mut().take() {
            pausing.abort();
        }
        let players = std::mem::take(&mut *self.paused.borrow_mut());
        if !players.is_empty() {
            gio::spawn_blocking(move || {
                for player in players {
                    call(&player, "Play");
                }
            });
        }
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
