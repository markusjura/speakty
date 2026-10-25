//! Soft ticks when dictation starts and when the text lands, and a beep for failures. They're drawn
//! here and played with pw-play, so they need no sound theme.

use std::f32::consts::TAU;
use std::path::PathBuf;

#[derive(Clone, Copy)]
pub enum Sound {
    Start,
    Done,
    Error,
}

impl Sound {
    fn name(self) -> &'static str {
        match self {
            Sound::Start => "start",
            Sound::Done => "done",
            Sound::Error => "error",
        }
    }

    /// Samples at 48 kHz.
    fn samples(self) -> Vec<f32> {
        let rate = 48_000.0;
        let tone = |seconds: f32, shape: &dyn Fn(f32) -> f32| -> Vec<f32> { (0..(seconds * rate) as usize).map(|i| shape(i as f32 / rate)).collect() };
        match self {
            // A bright tick, like Tink.
            Sound::Start => tone(0.09, &|t| ((TAU * 1975.0 * t).sin() * 0.6 + (TAU * 3950.0 * t).sin() * 0.25) * (-t * 55.0).exp()),
            // A rounder drop, like Pop.
            Sound::Done => tone(0.08, &|t| (TAU * (900.0 - 2500.0 * t) * t).sin() * (-t * 45.0).exp() * (t * 800.0).min(1.0)),
            Sound::Error => tone(0.32, &|t| {
                let on = (t % 0.16) < 0.11;
                if on { (TAU * 440.0 * t).sin() * 0.5 } else { 0.0 }
            }),
        }
    }

    fn file(self) -> Option<PathBuf> {
        let path = gtk::glib::user_runtime_dir().join("speakty").join(format!("{}.wav", self.name()));
        if path.exists() {
            return Some(path);
        }
        std::fs::create_dir_all(path.parent()?).ok()?;
        let spec = hound::WavSpec { channels: 1, sample_rate: 48_000, bits_per_sample: 16, sample_format: hound::SampleFormat::Int };
        let mut writer = hound::WavWriter::create(&path, spec).ok()?;
        for sample in self.samples() {
            writer.write_sample((sample * i16::MAX as f32) as i16).ok()?;
        }
        writer.finalize().ok()?;
        Some(path)
    }
}

pub fn play(sound: Sound) {
    std::thread::spawn(move || {
        let Some(file) = sound.file() else { return };
        let volume = if matches!(sound, Sound::Error) { "0.5" } else { "0.35" };
        let _ = std::process::Command::new("pw-play").args(["--volume", volume, "--media-role", "Notification"]).arg(file).status();
    });
}
