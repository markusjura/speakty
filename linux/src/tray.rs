//! The optional tray icon, through the StatusNotifierItem protocol that KDE, Waybar's tray module,
//! and most bars show. Off by default; Speakty opens from the app launcher.

use ksni::blocking::TrayMethods;
use ksni::menu::StandardItem;

#[derive(Clone, Copy, Debug)]
pub enum Command {
    ToggleDictation,
    Settings,
    Quit,
}

struct SpeaktyTray {
    recording: bool,
    can_start: bool,
    commands: async_channel::Sender<Command>,
}

impl ksni::Tray for SpeaktyTray {
    fn id(&self) -> String {
        crate::identity::APP_ID.into()
    }

    fn title(&self) -> String {
        crate::identity::NAME.into()
    }

    fn icon_name(&self) -> String {
        if self.recording { "media-record-symbolic" } else { "audio-input-microphone-symbolic" }.into()
    }

    fn activate(&mut self, _x: i32, _y: i32) {
        let _ = self.commands.send_blocking(Command::Settings);
    }

    fn menu(&self) -> Vec<ksni::MenuItem<Self>> {
        let item = |label: &str, command: Command, enabled: bool| -> ksni::MenuItem<Self> {
            StandardItem {
                label: label.into(),
                enabled,
                activate: Box::new(move |tray: &mut Self| {
                    let _ = tray.commands.send_blocking(command);
                }),
                ..Default::default()
            }
            .into()
        };
        vec![
            if self.recording {
                item("Stop Dictation", Command::ToggleDictation, true)
            } else {
                item("Start Dictation", Command::ToggleDictation, self.can_start)
            },
            ksni::MenuItem::Separator,
            item("Settings…", Command::Settings, true),
            item(&format!("Quit {}", crate::identity::NAME), Command::Quit, true),
        ]
    }
}

pub struct Tray(ksni::blocking::Handle<SpeaktyTray>);

impl Tray {
    pub fn spawn(commands: async_channel::Sender<Command>) -> Option<Self> {
        let tray = SpeaktyTray { recording: false, can_start: false, commands };
        // Without a tray host yet, it appears once a bar starts one.
        match tray.assume_sni_available(true).spawn() {
            Ok(handle) => Some(Self(handle)),
            Err(error) => {
                log::warn!("No tray icon: {error}");
                None
            }
        }
    }

    pub fn set_state(&self, recording: bool, can_start: bool) {
        self.0.update(|tray| {
            tray.recording = recording;
            tray.can_start = can_start;
        });
    }
}

impl Drop for Tray {
    fn drop(&mut self) {
        let _ = self.0.shutdown();
    }
}
