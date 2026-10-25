//! Settings: a sidebar plus one preferences page per pane, as on macOS, in libadwaita's style.
//! Every control writes straight to the preference store, which saves immediately and refuses
//! invalid values. Panes are built when shown, so they always start from the current values.

use crate::app::App;
use crate::hotkey;
use crate::identity;
use crate::install;
use crate::preferences::{Appearance, OverlayPosition, OverlayStyle, Preferences, Recording, ShortcutMode};
use crate::shortcut::{Modifiers, Shortcut, is_modifier};
use crate::transcriber::State;
use crate::transcript::Replacement;
use crate::updater::Status;
use adw::prelude::*;
use evdev::KeyCode;
use gtk::glib;
use std::cell::{Cell, RefCell};
use std::rc::{Rc, Weak};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Pane {
    General,
    Recording,
    Models,
    Transcript,
    Shortcuts,
    Permissions,
}

impl Pane {
    const ALL: [Pane; 6] = [Pane::General, Pane::Recording, Pane::Models, Pane::Transcript, Pane::Shortcuts, Pane::Permissions];

    /// The pane `speakty settings <name>` opens, by its title in lowercase.
    pub fn named(name: &str) -> Option<Pane> {
        Pane::ALL.into_iter().find(|pane| pane.title().eq_ignore_ascii_case(name))
    }

    fn title(self) -> &'static str {
        match self {
            Pane::General => "General",
            Pane::Recording => "Recording",
            Pane::Models => "Models",
            Pane::Transcript => "Transcript",
            Pane::Shortcuts => "Shortcuts",
            Pane::Permissions => "Permissions",
        }
    }

    fn icon(self) -> &'static str {
        match self {
            Pane::General => "preferences-system-symbolic",
            Pane::Recording => "audio-input-microphone-symbolic",
            Pane::Models => "application-x-executable-symbolic",
            Pane::Transcript => "format-justify-left-symbolic",
            Pane::Shortcuts => "input-keyboard-symbolic",
            Pane::Permissions => "system-lock-screen-symbolic",
        }
    }
}

pub struct Settings {
    window: adw::ApplicationWindow,
    split: adw::NavigationSplitView,
    sidebar: gtk::ListBox,
    pane: Cell<Pane>,
    app: Weak<App>,
    /// Ends a shortcut capture in progress without a new shortcut, which resumes the shortcut.
    end_capture: RefCell<Option<Rc<dyn Fn(Option<Shortcut>)>>>,
}

impl Settings {
    pub fn new(app: &Rc<App>) -> Rc<Self> {
        let window = adw::ApplicationWindow::builder()
            .application(&app.application)
            .title(format!("{} Settings", identity::NAME))
            .default_width(760)
            .default_height(600)
            .hide_on_close(true)
            .build();
        let sidebar = gtk::ListBox::new();
        sidebar.add_css_class("navigation-sidebar");
        for pane in Pane::ALL {
            let row = gtk::Box::new(gtk::Orientation::Horizontal, 12);
            row.set_margin_top(8);
            row.set_margin_bottom(8);
            row.set_margin_start(6);
            row.append(&gtk::Image::from_icon_name(pane.icon()));
            row.append(&gtk::Label::new(Some(pane.title())));
            sidebar.append(&row);
        }
        let sidebar_view = adw::ToolbarView::new();
        sidebar_view.add_top_bar(&adw::HeaderBar::new());
        sidebar_view.set_content(Some(&sidebar));
        let split = adw::NavigationSplitView::new();
        split.set_sidebar(Some(&adw::NavigationPage::new(&sidebar_view, identity::NAME)));
        split.set_min_sidebar_width(190.0);
        window.set_content(Some(&split));
        let settings = Rc::new(Self {
            window,
            split,
            sidebar,
            pane: Cell::new(Pane::General),
            app: Rc::downgrade(app),
            end_capture: RefCell::default(),
        });
        let weak = Rc::downgrade(&settings);
        settings.window.connect_hide(move |_| {
            if let Some(settings) = weak.upgrade() {
                settings.end_capture();
            }
        });
        let weak = Rc::downgrade(&settings);
        settings.sidebar.connect_row_activated(move |_, row| {
            if let Some(settings) = weak.upgrade() {
                settings.show(Pane::ALL[row.index() as usize]);
            }
        });
        settings
    }

    pub fn present(self: &Rc<Self>, pane: Option<Pane>) {
        self.show(pane.unwrap_or(self.pane.get()));
        self.window.present();
    }

    fn end_capture(&self) {
        let end = self.end_capture.borrow_mut().take();
        if let Some(end) = end {
            end(None);
        }
    }

    fn show(self: &Rc<Self>, pane: Pane) {
        let Some(app) = self.app.upgrade() else { return };
        self.end_capture();
        self.pane.set(pane);
        if let Some(row) = self.sidebar.row_at_index(Pane::ALL.iter().position(|p| *p == pane).unwrap() as i32) {
            self.sidebar.select_row(Some(&row));
        }
        let page = adw::PreferencesPage::new();
        match pane {
            Pane::General => general(&page, &app),
            Pane::Recording => recording(&page, &app),
            Pane::Models => models(&page, &app),
            Pane::Transcript => transcript(&page, &app, self),
            Pane::Shortcuts => shortcuts(&page, &app, self),
            Pane::Permissions => permissions(&page, &app),
        }
        let view = adw::ToolbarView::new();
        view.add_top_bar(&adw::HeaderBar::new());
        view.set_content(Some(&page));
        self.split.set_content(Some(&adw::NavigationPage::new(&view, pane.title())));
        self.split.set_show_content(true);
    }
}

/// Writes one change to the preferences.
fn set(app: &Rc<App>, change: impl FnOnce(&mut Preferences)) {
    app.preferences.update(change);
}

fn group(page: &adw::PreferencesPage, title: &str, description: Option<&str>) -> adw::PreferencesGroup {
    let group = adw::PreferencesGroup::builder().title(title).build();
    if let Some(description) = description {
        group.set_description(Some(description));
    }
    page.add(&group);
    group
}

fn switch(group: &adw::PreferencesGroup, app: &Rc<App>, title: &str, value: bool, change: impl Fn(&mut Preferences, bool) + 'static) -> adw::SwitchRow {
    let row = adw::SwitchRow::builder().title(title).active(value).build();
    let app = app.clone();
    row.connect_active_notify(move |row| {
        let active = row.is_active();
        set(&app, |p| change(p, active));
    });
    group.add(&row);
    row
}

fn choice(group: &adw::PreferencesGroup, app: &Rc<App>, title: &str, options: &[&str], selected: usize, change: impl Fn(&mut Preferences, usize) + 'static) -> adw::ComboRow {
    let row = adw::ComboRow::builder().title(title).model(&gtk::StringList::new(options)).selected(selected as u32).build();
    let app = app.clone();
    row.connect_selected_notify(move |row| {
        let index = row.selected() as usize;
        set(&app, |p| change(p, index));
    });
    group.add(&row);
    row
}

fn general(page: &adw::PreferencesPage, app: &Rc<App>) {
    let preferences = app.preferences.get();
    let appearance = group(page, "Appearance", None);
    let themes = [Appearance::System, Appearance::Light, Appearance::Dark];
    let selected = themes.iter().position(|t| *t == preferences.general.appearance).unwrap_or(0);
    choice(&appearance, app, "Theme", &["System", "Light", "Dark"], selected, move |p, i| p.general.appearance = themes[i]);

    let app_group = group(page, "App", None);
    switch(&app_group, app, "Show in tray", preferences.general.shows_tray_icon, |p, on| p.general.shows_tray_icon = on)
        .set_subtitle("For bars with a tray, such as Waybar's tray module");
    let login = adw::SwitchRow::builder().title("Open at login").build();
    if identity::IS_DEV {
        login.set_subtitle("Only the installed Speakty opens at login");
        login.set_sensitive(false);
    } else {
        let enabled = std::process::Command::new("systemctl")
            .args(["--user", "is-enabled", "--quiet", identity::SERVICE])
            .status()
            .is_ok_and(|s| s.success());
        login.set_active(enabled);
        login.connect_active_notify(|row| {
            let verb = if row.is_active() { "enable" } else { "disable" };
            if let Err(error) = install::systemctl(&[verb, identity::SERVICE]) {
                log::error!("{error}");
            }
        });
    }
    app_group.add(&login);

    let updates = group(page, "Updates", None);
    let updater = app.updater.clone();
    let running = updater.is_running();
    switch(&updates, app, "Check automatically", preferences.general.checks_for_updates, |p, on| p.general.checks_for_updates = on)
        .set_sensitive(running);
    let install = switch(&updates, app, "Install automatically", preferences.general.installs_updates, |p, on| p.general.installs_updates = on);
    install.set_subtitle("Relaunches into an update when no dictation runs and the keyboard rests");
    install.set_sensitive(running);
    let version = adw::ActionRow::builder().title(format!("{} {}", identity::NAME, identity::VERSION)).build();
    let button = gtk::Button::builder().valign(gtk::Align::Center).build();
    version.add_suffix(&button);
    updates.add(&version);
    let (row, action) = (version.downgrade(), button.downgrade());
    let last_checked = updater.last_checked.clone();
    let refresh = move |status: &Status| {
        let (Some(row), Some(button)) = (row.upgrade(), action.upgrade()) else { return };
        let checked = last_checked.get().and_then(|t| {
            let seconds = t.duration_since(std::time::UNIX_EPOCH).ok()?.as_secs() as i64;
            glib::DateTime::from_unix_local(seconds).ok()?.format("%e %b, %H:%M").ok()
        });
        let (subtitle, label, sensitive) = match status {
            _ if !running => ("Speakty Dev updates only from a test feed".to_string(), "Check Now", false),
            Status::Idle => (checked.map_or("Not checked yet".into(), |c| format!("Up to date · checked {}", c.trim())), "Check Now", true),
            Status::Checking => ("Checking…".into(), "Check Now", false),
            Status::Failed(error) => (format!("Couldn't update: {error}"), "Check Now", true),
            Status::Downloading(m) => (format!("Downloading {}…", m.version), "Check Now", false),
            Status::Available(m) => (format!("{} is available", m.version), "Install", true),
            Status::Ready(m) => (format!("{} is ready and installs when you're idle", m.version), "Restart Now", true),
        };
        row.set_subtitle(&subtitle);
        button.set_label(label);
        button.set_sensitive(sensitive);
    };
    updater.status.watch(refresh);
    button.connect_clicked(move |_| match updater.status.get() {
        Status::Available(_) | Status::Ready(_) => updater.install_available(),
        _ => updater.check_now(false),
    });
}

fn recording(page: &adw::PreferencesPage, app: &Rc<App>) {
    let recording = app.preferences.get().recording;
    let display = group(page, "Display", None);
    let styles = [OverlayStyle::Dark, OverlayStyle::Orb];
    let selected = styles.iter().position(|s| *s == recording.style).unwrap_or(0);
    choice(&display, app, "Style", &["Dark", "Orb"], selected, move |p, i| p.recording.style = styles[i]);
    let size = adw::SpinRow::with_range(*Recording::SCALE_RANGE.start() * 100.0, *Recording::SCALE_RANGE.end() * 100.0, 5.0);
    size.set_title("Size");
    size.set_subtitle("Percent of the default size");
    size.set_value(recording.scale * 100.0);
    let size_app = app.clone();
    size.connect_value_notify(move |row| set(&size_app, |p| p.recording.scale = (row.value() / 100.0).clamp(0.75, 2.0)));
    display.add(&size);
    let positions = [OverlayPosition::Bottom, OverlayPosition::Top];
    let selected = positions.iter().position(|s| *s == recording.position).unwrap_or(0);
    choice(&display, app, "Position", &["Bottom", "Top"], selected, move |p, i| p.recording.position = positions[i]);
    let distance = adw::SpinRow::with_range(*Recording::EDGE_DISTANCE_RANGE.start(), *Recording::EDGE_DISTANCE_RANGE.end(), 2.0);
    distance.set_title("Distance from edge");
    distance.set_subtitle("Pixels");
    distance.set_value(recording.edge_distance);
    let distance_app = app.clone();
    distance.connect_value_notify(move |row| set(&distance_app, |p| p.recording.edge_distance = row.value()));
    display.add(&distance);

    let microphone = group(page, "Microphone", None);
    let sources = app.dictation.recorder.sources();
    let mut names: Vec<Option<String>> = vec![None];
    let mut labels = vec!["System default".to_string()];
    for source in &sources {
        names.push(Some(source.name.clone()));
        labels.push(source.description.clone());
    }
    if let Some(stored) = recording.microphone.as_ref().filter(|m| !sources.iter().any(|s| &s.name == *m)) {
        names.push(Some(stored.clone()));
        labels.push("Disconnected microphone".into());
    }
    let selected = names.iter().position(|n| *n == recording.microphone).unwrap_or(0);
    let labels: Vec<&str> = labels.iter().map(String::as_str).collect();
    choice(&microphone, app, "Input", &labels, selected, move |p, i| p.recording.microphone = names[i].clone());

    let sound = group(page, "Sound", None);
    switch(&sound, app, "Play sounds", recording.plays_sounds, |p, on| p.recording.plays_sounds = on);
    switch(&sound, app, "Mute audio while recording", recording.mutes_audio, |p, on| p.recording.mutes_audio = on);
    switch(&sound, app, "Pause media while recording", recording.pauses_media, |p, on| p.recording.pauses_media = on);
}

fn models(page: &adw::PreferencesPage, app: &Rc<App>) {
    let transcriber = app.transcriber.clone();
    let model = transcriber.model;
    let group = group(page, "Dictation model", Some("Runs on this computer's CPU. Nothing you say leaves it."));
    let row = adw::ActionRow::builder().title(model.title).build();
    let button = gtk::Button::builder().valign(gtk::Align::Center).build();
    let progress = gtk::ProgressBar::builder().valign(gtk::Align::Center).width_request(120).build();
    row.add_suffix(&progress);
    row.add_suffix(&button);
    group.add(&row);
    let (weak_row, weak_button, weak_progress) = (row.downgrade(), button.downgrade(), progress.downgrade());
    transcriber.state.watch(move |state| {
        let (Some(row), Some(button), Some(progress)) = (weak_row.upgrade(), weak_button.upgrade(), weak_progress.upgrade()) else { return };
        let (subtitle, label) = match state {
            State::Absent => (format!("{} · {}", model.summary, model.size), Some("Download")),
            State::Downloading(fraction) => (format!("Downloading · {:.0} % of {}", fraction * 100.0, model.size), None),
            State::Loading => ("Loading…".into(), None),
            State::Ready => (model.summary.into(), Some("Remove")),
            State::Failed(error) => (format!("Failed: {error}"), Some("Try Again")),
        };
        row.set_subtitle(&subtitle);
        progress.set_visible(matches!(state, State::Downloading(_)));
        if let State::Downloading(fraction) = state {
            progress.set_fraction(*fraction);
        }
        button.set_visible(label.is_some());
        button.set_label(label.unwrap_or_default());
        button.remove_css_class("destructive-action");
        if *state == State::Ready {
            button.add_css_class("destructive-action");
        }
    });
    button.connect_clicked(move |_| {
        if transcriber.state.get() == State::Ready {
            transcriber.remove();
        } else {
            transcriber.prepare();
        }
    });
}

fn transcript(page: &adw::PreferencesPage, app: &Rc<App>, settings: &Rc<Settings>) {
    let preferences = app.preferences.get().transcript;
    let rebuild = {
        let settings = Rc::downgrade(settings);
        move || {
            if let Some(settings) = settings.upgrade() {
                // After the click that changed the list, which is still running.
                glib::idle_add_local_once(move || settings.show(Pane::Transcript));
            }
        }
    };

    let vocabulary = group(page, "Vocabulary", Some("Names and terms that recognition should lean toward, such as product names."));
    let add = adw::EntryRow::builder().title("Add a word or name").show_apply_button(true).build();
    let (add_app, add_rebuild) = (app.clone(), rebuild.clone());
    add.connect_apply(move |entry| {
        let word = entry.text().trim().to_string();
        if word.is_empty() {
            return;
        }
        set(&add_app, |p| {
            p.transcript.vocabulary.retain(|w| *w != word);
            p.transcript.vocabulary.insert(0, word);
        });
        add_rebuild();
    });
    vocabulary.add(&add);
    for word in preferences.vocabulary {
        let row = adw::ActionRow::builder().title(glib::markup_escape_text(&word).as_str()).build();
        let remove = remove_button();
        let (remove_app, remove_rebuild) = (app.clone(), rebuild.clone());
        remove.connect_clicked(move |_| {
            set(&remove_app, |p| p.transcript.vocabulary.retain(|w| *w != word));
            remove_rebuild();
        });
        row.add_suffix(&remove);
        vocabulary.add(&row);
    }

    let replacements = group(page, "Replacements", Some("Applied top to bottom. Plain text matches whole words and ignores case; a pattern is a regular expression, with $1 for its groups."));
    for (index, rule) in preferences.replacements.iter().enumerate() {
        let row = adw::ActionRow::builder()
            .title(glib::markup_escape_text(&format!("{}  →  {}", rule.find, rule.replacement)).as_str())
            .subtitle(if rule.is_pattern { "Pattern" } else { "Text" })
            .build();
        let remove = remove_button();
        let (remove_app, remove_rebuild) = (app.clone(), rebuild.clone());
        remove.connect_clicked(move |_| {
            set(&remove_app, |p| {
                if index < p.transcript.replacements.len() {
                    p.transcript.replacements.remove(index);
                }
            });
            remove_rebuild();
        });
        row.add_suffix(&remove);
        replacements.add(&row);
    }
    let find = adw::EntryRow::builder().title("Find").build();
    let replacement = adw::EntryRow::builder().title("Replace with").build();
    let pattern = adw::SwitchRow::builder().title("Regular expression").build();
    let add_rule = gtk::Button::builder().label("Add Replacement").halign(gtk::Align::End).margin_top(8).build();
    add_rule.add_css_class("suggested-action");
    let (rule_app, rule_rebuild) = (app.clone(), rebuild);
    let (f, r, p) = (find.clone(), replacement.clone(), pattern.clone());
    add_rule.connect_clicked(move |_| {
        let rule = Replacement { find: f.text().to_string(), replacement: r.text().to_string(), is_pattern: p.is_active() };
        if !rule.is_valid() {
            f.add_css_class("error");
            return;
        }
        set(&rule_app, |prefs| prefs.transcript.replacements.push(rule));
        rule_rebuild();
    });
    replacements.add(&find);
    replacements.add(&replacement);
    replacements.add(&pattern);
    replacements.add(&add_rule);

    let formatting = group(page, "Formatting", None);
    switch(&formatting, app, "Smart paragraphs", preferences.splits_paragraphs, |p, on| p.transcript.splits_paragraphs = on)
        .set_subtitle("Splits a long transcript into paragraphs, and starts one where you say \"new paragraph\"");
}

fn remove_button() -> gtk::Button {
    let button = gtk::Button::from_icon_name("user-trash-symbolic");
    button.set_valign(gtk::Align::Center);
    button.add_css_class("flat");
    button.set_tooltip_text(Some("Remove"));
    button
}

fn shortcuts(page: &adw::PreferencesPage, app: &Rc<App>, settings: &Rc<Settings>) {
    let recording = app.preferences.get().recording;
    let dictation = group(page, "Dictation", Some("Wayland lets no app take a key from the others, so the shortcut also reaches the app in front. A modifier key on its own, such as Right Super, does nothing there."));
    let row = adw::ActionRow::builder().title("Shortcut").build();
    row.add_suffix(&shortcut_button(app, settings, Command::Dictate));
    dictation.add(&row);
    let modes = [ShortcutMode::HoldOrTap, ShortcutMode::Hold, ShortcutMode::Tap];
    let selected = modes.iter().position(|m| *m == recording.shortcut_mode).unwrap_or(0);
    choice(&dictation, app, "Mode", &["Hold or tap", "Hold", "Tap"], selected, move |p, i| p.recording.shortcut_mode = modes[i])
        .set_subtitle("A hold records until you let go, and a tap until you press again");

    let during = group(page, "While dictating", None);
    let cancel = adw::ActionRow::builder().title("Cancel").subtitle("Discards the dictation").build();
    cancel.add_suffix(&shortcut_button(app, settings, Command::Cancel));
    let clear = remove_button();
    clear.set_tooltip_text(Some("Turn off"));
    let clear_app = app.clone();
    clear.connect_clicked(move |_| set(&clear_app, |p| p.recording.cancel_shortcut = None));
    cancel.add_suffix(&clear);
    during.add(&cancel);
}

#[derive(Clone, Copy, PartialEq)]
enum Command {
    Dictate,
    Cancel,
}

fn shortcut_title(app: &App, command: Command) -> String {
    let recording = app.preferences.get().recording;
    match command {
        Command::Dictate => recording.shortcut.title(),
        Command::Cancel => recording.cancel_shortcut.map_or("Off".into(), |s| s.title()),
    }
}

/// A button that shows a shortcut and records a new one when clicked: the next key with its
/// modifiers, or a modifier key pressed and released on its own. Esc stops recording the dictation shortcut.
fn shortcut_button(app: &Rc<App>, settings: &Rc<Settings>, command: Command) -> gtk::Button {
    let button = gtk::Button::builder().label(shortcut_title(app, command)).valign(gtk::Align::Center).build();
    let controller: Rc<RefCell<Option<gtk::EventControllerKey>>> = Rc::default();
    let (app, window, settings) = (app.clone(), settings.window.clone(), Rc::downgrade(settings));
    button.connect_clicked(move |button| {
        if controller.borrow().is_some() {
            return;
        }
        let Some(settings) = settings.upgrade() else { return };
        // One capture at a time: another button's ends without a shortcut.
        settings.end_capture();
        button.set_label("Press a shortcut…");
        app.recording_shortcut.set(true);
        app.sync_watch();
        let keys = gtk::EventControllerKey::new();
        keys.set_propagation_phase(gtk::PropagationPhase::Capture);
        let pending_modifier: Rc<Cell<Option<KeyCode>>> = Rc::default();
        let finish = {
            let (app, button, window, controller, owner) =
                (app.clone(), button.clone(), window.clone(), controller.clone(), Rc::downgrade(&settings));
            Rc::new(move |shortcut: Option<Shortcut>| {
                if let Some(settings) = owner.upgrade() {
                    settings.end_capture.borrow_mut().take();
                }
                if let Some(shortcut) = shortcut {
                    set(&app, |p| match command {
                        Command::Dictate if shortcut.works_globally() => {
                            // The command already using it gives it up.
                            if p.recording.cancel_shortcut == Some(shortcut) {
                                p.recording.cancel_shortcut = None;
                            }
                            p.recording.shortcut = shortcut;
                        }
                        Command::Dictate => {}
                        Command::Cancel if shortcut != p.recording.shortcut => p.recording.cancel_shortcut = Some(shortcut),
                        Command::Cancel => {}
                    });
                }
                if let Some(keys) = controller.borrow_mut().take() {
                    window.remove_controller(&keys);
                }
                app.recording_shortcut.set(false);
                app.sync_watch();
                button.set_label(&shortcut_title(&app, command));
            })
        };
        let (pressed_modifier, pressed_finish) = (pending_modifier.clone(), finish.clone());
        keys.connect_key_pressed(move |_, _, keycode, state| {
            // Wayland's keycodes are evdev's plus 8.
            let key = KeyCode::new(keycode.saturating_sub(8) as u16);
            if is_modifier(key) {
                pressed_modifier.set(Some(key));
                return glib::Propagation::Stop;
            }
            pressed_modifier.set(None);
            let modifiers = Modifiers {
                ctrl: state.contains(gtk::gdk::ModifierType::CONTROL_MASK),
                alt: state.contains(gtk::gdk::ModifierType::ALT_MASK),
                shift: state.contains(gtk::gdk::ModifierType::SHIFT_MASK),
                logo: state.contains(gtk::gdk::ModifierType::SUPER_MASK),
            };
            let shortcut = Shortcut { key, modifiers };
            let stops = command == Command::Dictate && key == KeyCode::KEY_ESC && modifiers.is_empty();
            pressed_finish(if stops { None } else { Some(shortcut) });
            glib::Propagation::Stop
        });
        let released_finish = finish.clone();
        keys.connect_key_released(move |_, _, keycode, _| {
            let key = KeyCode::new(keycode.saturating_sub(8) as u16);
            if pending_modifier.get() == Some(key) {
                released_finish(Some(Shortcut::key(key)));
            }
        });
        window.add_controller(keys.clone());
        *controller.borrow_mut() = Some(keys);
        *settings.end_capture.borrow_mut() = Some(finish);
    });
    button
}

fn permissions(page: &adw::PreferencesPage, app: &Rc<App>) {
    let status = |ok: bool| if ok { "Allowed" } else { "Not allowed" };
    let keyboards = app.hotkeys.can_read_keyboards().unwrap_or(false);
    let keyboard = group(page, "Keyboard", Some("Speakty reads the keyboards in /dev/input to see the dictation shortcut, which needs the input group."));
    let row = adw::ActionRow::builder().title("Read the keyboards").subtitle(status(keyboards)).build();
    keyboard.add(&row);
    if !keyboards {
        keyboard.add(&command_row("Then log out and in again", "sudo usermod -aG input $USER"));
    }
    let can_paste = app.paster.can_paste();
    let pasting = group(page, "Pasting", Some("Speakty pastes with a virtual keyboard, which needs write access to /dev/uinput. Without it, transcripts stay on the clipboard."));
    let row = adw::ActionRow::builder().title("Virtual keyboard").subtitle(status(can_paste)).build();
    pasting.add(&row);
    if !can_paste || !hotkey::can_write_uinput() {
        pasting.add(&command_row(
            "Then restart Speakty",
            "echo 'KERNEL==\"uinput\", GROUP=\"input\", MODE=\"0660\", OPTIONS+=\"static_node=uinput\"' | sudo tee /etc/udev/rules.d/70-speakty-uinput.rules && sudo udevadm control --reload && sudo udevadm trigger /dev/uinput",
        ));
    }
    group(page, "Microphone", Some("PipeWire gives apps the microphone without asking. Choose it in Recording."));
}

/// A command to run in a terminal, selectable so it can be copied.
fn command_row(subtitle: &str, command: &str) -> adw::ActionRow {
    let row = adw::ActionRow::builder().title(glib::markup_escape_text(command).as_str()).subtitle(subtitle).build();
    row.add_css_class("monospace");
    row.set_title_selectable(true);
    row
}
