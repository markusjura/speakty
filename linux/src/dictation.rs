//! One dictation at a time: record while the shortcut is held, or from a tap of the shortcut, or
//! `speakty toggle`, until the next press, then transcribe, post-process, and paste. Cancel discards
//! it at any point.

use crate::hotkey::Event;
use crate::media::MediaPauser;
use crate::muter::OutputMuter;
use crate::observable::Observable;
use crate::paste::Paster;
use crate::preferences::{ShortcutMode, Store};
use crate::recorder::Recorder;
use crate::sounds::{self, Sound};
use crate::transcriber::{self, Transcriber};
use crate::transcript;
use gtk::glib;
use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::time::{Duration, Instant};

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Phase {
    Idle,
    Recording(Trigger),
    Transcribing,
}

/// How the shortcut ends a recording.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Trigger {
    /// Down since this instant. The release ends the recording or, as a tap, latches it.
    Held(Instant),
    /// Runs until the next press of the shortcut, or `speakty stop`.
    Latched,
}

/// What a shortcut event does.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Action {
    Start(Trigger),
    /// Keeps recording until the next press.
    Latch,
    Stop,
    Cancel,
    Ignore,
}

/// In Hold or tap, a release sooner than this after the press is a tap.
const LONGEST_TAP: Duration = Duration::from_millis(250);
/// Recording continues briefly after release, so a word finished while letting go isn't cut.
const RELEASE_TAIL: Duration = Duration::from_millis(200);
/// Muting waits for the start sound, which it would cut off. pw-play takes a moment to start it.
const MUTE_DELAY: Duration = Duration::from_millis(250);

/// Every press starts as a hold, and the mode decides what its release does. Another key typed
/// with a held modifier shortcut, as in Super+C with Right Super, means the press was a shortcut,
/// not dictation.
pub fn action(event: Event, phase: Phase, mode: ShortcutMode, now: Instant) -> Action {
    match (event, phase) {
        (Event::Pressed, Phase::Idle) => Action::Start(Trigger::Held(now)),
        (Event::Released, Phase::Recording(Trigger::Held(since))) => match mode {
            ShortcutMode::Hold => Action::Stop,
            ShortcutMode::Tap => Action::Latch,
            ShortcutMode::HoldOrTap if now.duration_since(since) < LONGEST_TAP => Action::Latch,
            ShortcutMode::HoldOrTap => Action::Stop,
        },
        (Event::Pressed, Phase::Recording(Trigger::Latched)) => Action::Stop,
        (Event::Interrupted, Phase::Recording(Trigger::Held(_))) => Action::Cancel,
        (Event::Cancel, Phase::Recording(_) | Phase::Transcribing) => Action::Cancel,
        _ => Action::Ignore,
    }
}

pub struct DictationController {
    pub phase: Rc<Observable<Phase>>,
    pub recorder: Recorder,
    preferences: Rc<Store>,
    transcriber: Rc<Transcriber>,
    paster: Paster,
    muter: OutputMuter,
    media: MediaPauser,
    work: RefCell<Option<glib::JoinHandle<()>>>,
    /// Counts recordings, so a microphone that starts late can tell whether its recording still runs.
    recordings: Cell<u64>,
}

impl DictationController {
    pub fn new(preferences: Rc<Store>, transcriber: Rc<Transcriber>, paster: Paster) -> Rc<Self> {
        Rc::new(Self {
            phase: Observable::new(Phase::Idle),
            recorder: Recorder::new(),
            preferences,
            transcriber,
            paster,
            muter: OutputMuter::new(),
            media: MediaPauser::new(),
            work: RefCell::default(),
            recordings: Cell::new(0),
        })
    }

    pub fn is_recording(&self) -> bool {
        matches!(self.phase.get(), Phase::Recording(_))
    }

    pub fn handle(self: &Rc<Self>, event: Event) {
        match action(event, self.phase.get(), self.preferences.get().recording.shortcut_mode, Instant::now()) {
            Action::Start(trigger) => self.start(trigger),
            Action::Latch => self.phase.set(Phase::Recording(Trigger::Latched)),
            Action::Stop => self.stop(),
            Action::Cancel => self.cancel(),
            Action::Ignore => {}
        }
    }

    /// Starts a recording that runs until the next `toggle`, or stops the one that runs.
    pub fn toggle(self: &Rc<Self>) {
        match self.phase.get() {
            Phase::Recording(_) => self.stop(),
            Phase::Idle => self.start(Trigger::Latched),
            Phase::Transcribing => {}
        }
    }

    fn start(self: &Rc<Self>, trigger: Trigger) {
        if self.transcriber.state.get() != transcriber::State::Ready {
            sounds::play(Sound::Error);
            return log::info!("Dictation waits for the model: {:?}", self.transcriber.state.get());
        }
        let preferences = self.preferences.get();
        self.recordings.set(self.recordings.get() + 1);
        let recording = self.recordings.get();
        let started = self.recorder.start(Store::stored_debug().microphone.or(preferences.recording.microphone.clone()));
        self.phase.set(Phase::Recording(trigger));
        let this = self.clone();
        glib::spawn_future_local(async move {
            // PipeWire answers within a second; without an answer it isn't running.
            let result = glib::future_with_timeout(Duration::from_secs(5), started.recv())
                .await
                .map_err(|_| "The microphone didn't start".to_string())
                .and_then(|answer| answer.unwrap_or_else(|_| Err("PipeWire isn't running".into())));
            if recording == this.recordings.get() {
                this.microphone_started(result);
            }
        });
    }

    /// The display shows at once; the start sound waits for the microphone, which can take half a
    /// second, so it tells when speech is heard.
    fn microphone_started(self: &Rc<Self>, result: Result<(), String>) {
        // Unless Cancel ended the recording meanwhile.
        if !self.is_recording() {
            return;
        }
        if let Err(error) = result {
            sounds::play(Sound::Error);
            log::error!("Recording didn't start: {error}");
            return self.cancel();
        }
        let recording = self.preferences.get().recording;
        if recording.plays_sounds {
            sounds::play(Sound::Start);
        }
        if recording.pauses_media {
            self.media.pause();
        }
        if recording.mutes_audio {
            let this = self.clone();
            *self.work.borrow_mut() = Some(glib::spawn_future_local(async move {
                glib::timeout_future(MUTE_DELAY).await;
                if this.is_recording() {
                    this.muter.mute();
                }
            }));
        }
    }

    fn stop(self: &Rc<Self>) {
        if !self.is_recording() {
            return;
        }
        self.phase.set(Phase::Transcribing);
        if let Some(work) = self.work.borrow_mut().take() {
            work.abort();
        }
        let this = self.clone();
        // Cancel aborts this at its next await, before it could touch a recording started since.
        *self.work.borrow_mut() = Some(glib::spawn_future_local(async move {
            glib::timeout_future(RELEASE_TAIL).await;
            let samples = this.recorder.stop().await;
            // Not before the tail ends, so resumed music doesn't end up in the recording.
            this.muter.restore();
            this.media.resume();
            this.finish(samples).await;
            this.work.borrow_mut().take();
            this.phase.set(Phase::Idle);
        }));
    }

    async fn finish(&self, samples: Vec<f32>) {
        let speech = transcript::speech(&samples);
        if speech.is_empty() {
            return log::info!("Heard no speech");
        }
        let preferences = self.preferences.get().transcript;
        let raw = match self.transcriber.transcribe(speech, preferences.vocabulary.clone()).await {
            Ok(raw) => raw,
            Err(error) => {
                sounds::play(Sound::Error);
                return log::error!("Transcription failed: {error}");
            }
        };
        let spelled = transcript::spelling(&raw, &preferences.vocabulary);
        let mut text = transcript::closing(transcript::applying(&preferences.replacements, &spelled).trim());
        if text.is_empty() {
            return;
        }
        if preferences.splits_paragraphs {
            text = transcript::paragraphs(&transcript::applying_paragraph_commands(&text));
        }
        // Smart spacing needs the text before the caret, which Linux apps don't share yet.
        self.paster.insert(text, false, preferences.copies_to_clipboard);
        if self.preferences.get().recording.plays_sounds {
            sounds::play(Sound::Done);
        }
    }

    /// Cancels a dictation and waits until the output and media are back, before Speakty exits.
    pub fn shut_down(&self) {
        self.cancel();
        self.muter.flush();
        self.media.flush();
    }

    pub fn cancel(&self) {
        if self.phase.get() == Phase::Idle {
            return;
        }
        if let Some(work) = self.work.borrow_mut().take() {
            work.abort();
        }
        self.recorder.cancel();
        self.muter.restore();
        self.media.resume();
        self.phase.set(Phase::Idle);
        log::info!("Cancelled");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn act(event: Event, phase: Phase, after_ms: u64, mode: ShortcutMode, start: Instant) -> Action {
        action(event, phase, mode, start + Duration::from_millis(after_ms))
    }

    #[test]
    fn a_hold_records_until_its_release_and_a_tap_until_the_next_press() {
        let start = Instant::now();
        let held = Phase::Recording(Trigger::Held(start));
        assert_eq!(act(Event::Pressed, Phase::Idle, 0, ShortcutMode::HoldOrTap, start), Action::Start(Trigger::Held(start)));
        assert_eq!(act(Event::Released, held, 900, ShortcutMode::HoldOrTap, start), Action::Stop);
        assert_eq!(act(Event::Released, held, 120, ShortcutMode::HoldOrTap, start), Action::Latch);
        assert_eq!(act(Event::Pressed, Phase::Recording(Trigger::Latched), 0, ShortcutMode::HoldOrTap, start), Action::Stop);
    }

    #[test]
    fn the_mode_decides_what_a_release_does() {
        let start = Instant::now();
        let held = Phase::Recording(Trigger::Held(start));
        assert_eq!(act(Event::Released, held, 120, ShortcutMode::Hold, start), Action::Stop);
        assert_eq!(act(Event::Released, held, 900, ShortcutMode::Tap, start), Action::Latch);
    }

    #[test]
    fn interruptions_and_cancel() {
        let start = Instant::now();
        let held = Phase::Recording(Trigger::Held(start));
        assert_eq!(act(Event::Interrupted, held, 0, ShortcutMode::HoldOrTap, start), Action::Cancel);
        assert_eq!(act(Event::Interrupted, Phase::Recording(Trigger::Latched), 0, ShortcutMode::HoldOrTap, start), Action::Ignore);
        assert_eq!(act(Event::Cancel, Phase::Transcribing, 0, ShortcutMode::HoldOrTap, start), Action::Cancel);
        assert_eq!(act(Event::Pressed, Phase::Transcribing, 0, ShortcutMode::HoldOrTap, start), Action::Ignore);
    }
}
