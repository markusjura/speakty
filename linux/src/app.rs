//! Creates the long-lived objects at launch and wires them together, as SpeaktyApplicationDelegate
//! does on macOS. One instance runs per user session: GApplication makes a second launch, such as
//! `speakty settings` from an app launcher, hand its command to the running one.

use crate::dictation::{DictationController, Phase};
use crate::hotkey::{self, HotkeyMonitor, Watch};
use crate::identity;
use crate::overlay::Overlay;
use crate::paste::Paster;
use crate::preferences::{Appearance, Preferences, Store};
use crate::settings::{Pane, Settings};
use crate::transcriber::{self, Transcriber};
use crate::tray::{self, Tray};
use crate::updater::Updater;
use adw::prelude::*;
use gtk::{gio, glib};
use std::cell::{Cell, RefCell};
use std::rc::Rc;

pub struct App {
    pub application: adw::Application,
    pub preferences: Rc<Store>,
    pub transcriber: Rc<Transcriber>,
    pub dictation: Rc<DictationController>,
    pub hotkeys: HotkeyMonitor,
    pub updater: Rc<Updater>,
    pub paster: Paster,
    /// Set while Settings records a shortcut, so the current one doesn't fire.
    pub recording_shortcut: Cell<bool>,
    overlay: Rc<Overlay>,
    settings: RefCell<Option<Rc<Settings>>>,
    tray: RefCell<Option<Tray>>,
    _hold: gio::ApplicationHoldGuard,
}

impl App {
    fn new(application: &adw::Application) -> Rc<Self> {
        let preferences = Rc::new(Store::load());
        let transcriber = Transcriber::new();
        let paster = Paster::new();
        let dictation = DictationController::new(preferences.clone(), transcriber.clone(), paster.clone());
        let (events, received) = async_channel::unbounded();
        let hotkeys = HotkeyMonitor::start(watch(&preferences.get(), Phase::Idle, false), events);
        let overlay = Overlay::new(application, dictation.recorder.clone());
        let busy = dictation.clone();
        let idle = hotkeys.clone();
        let updater = Updater::new(preferences.clone(), move || busy.phase.get() != Phase::Idle, move || idle.idle_time());
        let app = Rc::new(Self {
            application: application.clone(),
            preferences,
            transcriber,
            dictation,
            hotkeys,
            updater,
            paster,
            recording_shortcut: Cell::new(false),
            overlay,
            settings: RefCell::default(),
            tray: RefCell::default(),
            _hold: application.hold(),
        });

        let dictation = app.dictation.clone();
        glib::spawn_future_local(async move {
            while let Ok(event) = received.recv().await {
                dictation.handle(event);
            }
        });
        let weak = Rc::downgrade(&app);
        app.preferences.value.watch(move |preferences| {
            if let Some(app) = weak.upgrade() {
                app.preferences_changed(preferences);
            }
        });
        let weak = Rc::downgrade(&app);
        app.dictation.phase.subscribe(move |&phase| {
            if let Some(app) = weak.upgrade() {
                app.overlay.update(phase, &app.preferences.get().recording);
                app.sync_watch();
                app.sync_tray();
            }
        });
        let weak = Rc::downgrade(&app);
        app.transcriber.state.subscribe(move |_| {
            if let Some(app) = weak.upgrade() {
                app.sync_tray();
            }
        });
        app.transcriber.prepare();
        app.updater.start();
        app
    }

    fn preferences_changed(self: &Rc<Self>, preferences: &Preferences) {
        adw::StyleManager::default().set_color_scheme(match preferences.general.appearance {
            Appearance::System => adw::ColorScheme::Default,
            Appearance::Light => adw::ColorScheme::ForceLight,
            Appearance::Dark => adw::ColorScheme::ForceDark,
        });
        self.overlay.update(self.dictation.phase.get(), &preferences.recording);
        self.sync_watch();
        let shows_tray = preferences.general.shows_tray_icon;
        if shows_tray != self.tray.borrow().is_some() {
            *self.tray.borrow_mut() = if shows_tray { self.spawn_tray() } else { None };
            self.sync_tray();
        }
    }

    /// Tells the keyboard readers the shortcut, and whether Cancel and the pause apply.
    pub fn sync_watch(&self) {
        self.hotkeys.set_watch(watch(&self.preferences.get(), self.dictation.phase.get(), self.recording_shortcut.get()));
    }

    fn spawn_tray(self: &Rc<Self>) -> Option<Tray> {
        let (commands, received) = async_channel::unbounded();
        let tray = Tray::spawn(commands)?;
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            while let Ok(command) = received.recv().await {
                let Some(app) = weak.upgrade() else { break };
                match command {
                    tray::Command::ToggleDictation => app.dictation.toggle(),
                    tray::Command::Settings => app.show_settings(None),
                    tray::Command::Quit => app.quit(),
                }
            }
        });
        Some(tray)
    }

    fn sync_tray(&self) {
        if let Some(tray) = self.tray.borrow().as_ref() {
            let ready = self.transcriber.state.get() == transcriber::State::Ready;
            tray.set_state(self.dictation.is_recording(), ready && self.dictation.phase.get() == Phase::Idle);
        }
    }

    /// Opens Settings, on `pane` when given, or brings it forward.
    pub fn show_settings(self: &Rc<Self>, pane: Option<Pane>) {
        let settings = self.settings.borrow_mut().get_or_insert_with(|| Settings::new(self)).clone();
        settings.present(pane);
    }

    /// Shutdown cancels a dictation in progress and waits for the output and media to come back.
    pub fn quit(&self) {
        self.application.quit();
    }

    /// Handles a command line, from this launch or one handed over by a later launch.
    fn command(self: &Rc<Self>, arguments: &[String], is_first_launch: bool, line: &gio::ApplicationCommandLine) -> i32 {
        let command = arguments.first().map(String::as_str);
        if is_first_launch && command.is_some_and(|c| c != "settings") {
            line.printerr_literal(&format!("{} isn't running.\n", identity::NAME));
            self.quit();
            return 1;
        }
        match command {
            None if is_first_launch => {
                // The first launch opens Settings where something still needs doing.
                if self.hotkeys.can_read_keyboards() == Some(false) || !self.paster.can_paste() {
                    self.show_settings(Some(Pane::Permissions));
                } else if self.transcriber.state.get() == transcriber::State::Absent || !self.preferences_exist() {
                    self.show_settings(Some(Pane::Models));
                }
            }
            None => self.show_settings(None),
            Some("settings") => self.show_settings(arguments.get(1).and_then(|name| Pane::named(name))),
            Some("start") if !self.dictation.is_recording() => self.dictation.toggle(),
            Some("stop") if self.dictation.is_recording() => self.dictation.toggle(),
            Some("start" | "stop") => {}
            Some("toggle") => self.dictation.toggle(),
            Some("cancel") => self.dictation.cancel(),
            Some("status") => line.print_literal(&format!(
                "{} {}\nphase: {:?}\nmodel: {:?}\nkeyboards readable: {:?}\ncan paste: {}\nupdates: {:?}\n",
                identity::NAME,
                identity::VERSION,
                self.dictation.phase.get(),
                self.transcriber.state.get(),
                self.hotkeys.can_read_keyboards(),
                self.paster.can_paste(),
                self.updater.status.get(),
            )),
            Some("update") => self.updater.check_now(true),
            Some("quit") => self.quit(),
            Some(other) => {
                line.printerr_literal(&format!("Unknown command {other}. Run speakty help.\n"));
                return 2;
            }
        }
        0
    }

    fn preferences_exist(&self) -> bool {
        Store::path().exists()
    }
}

fn watch(preferences: &Preferences, phase: Phase, paused: bool) -> Watch {
    Watch {
        shortcut: preferences.recording.shortcut,
        cancel: preferences.recording.cancel_shortcut,
        dictating: phase != Phase::Idle,
        paused,
    }
}

thread_local! {
    static APP: RefCell<Option<Rc<App>>> = const { RefCell::new(None) };
}

pub fn run(arguments: Vec<String>) -> glib::ExitCode {
    let application = adw::Application::builder()
        .application_id(identity::APP_ID)
        .flags(gio::ApplicationFlags::HANDLES_COMMAND_LINE)
        .build();
    application.connect_startup(|application| {
        log::info!("{} {} starting", identity::NAME, identity::VERSION);
        if !hotkey::can_write_uinput() {
            log::warn!("Can't write /dev/uinput, so transcripts stay on the clipboard");
        }
        APP.with(|app| *app.borrow_mut() = Some(App::new(application)));
        // systemctl stop and Ctrl+C quit as the Quit command does, so the output never stays muted.
        for signal in [15, 2] {
            let application = application.clone();
            glib_unix::unix_signal_add_local_once(signal, move || application.quit());
        }
    });
    let launched = Cell::new(false);
    application.connect_command_line(move |_, line| {
        let arguments: Vec<String> = line.arguments().iter().skip(1).map(|a| a.to_string_lossy().into_owned()).collect();
        let is_first_launch = !launched.replace(true);
        let Some(app) = APP.with(|app| app.borrow().clone()) else { return glib::ExitCode::FAILURE };
        glib::ExitCode::from(app.command(&arguments, is_first_launch, line) as u8)
    });
    application.connect_shutdown(|_| APP.with(|app| {
        if let Some(app) = app.borrow_mut().take() {
            app.dictation.shut_down();
        }
    }));
    application.run_with_args(&arguments)
}
