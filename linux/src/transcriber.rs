//! Downloads, loads, and runs the dictation model, Parakeet Ultra, on the CPU through sherpa-onnx.
//! The vocabulary goes in as hotwords: beam search leans toward them where the audio supports
//! them, which does on Linux what the CTC rescoring pass does on macOS.

use crate::identity;
use crate::observable::Observable;
use crate::transcript::SAMPLE_RATE;
use sha2::{Digest, Sha256};
use sherpa_onnx::{OfflineRecognizer, OfflineRecognizerConfig};
use std::cell::{Cell, RefCell};
use std::io::{Read, Write};
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Arc;

#[derive(Clone, Debug, PartialEq)]
pub enum State {
    Absent,
    /// Fraction downloaded, 0 to 1.
    Downloading(f64),
    Loading,
    Ready,
    Failed(String),
}

/// The dictation model. Another model would become another row in Settings > Models.
pub struct Model {
    pub title: &'static str,
    pub summary: &'static str,
    pub size: &'static str,
    directory: &'static str,
    files: &'static [ModelFile],
}

struct ModelFile {
    name: &'static str,
    bytes: u64,
    sha256: &'static str,
}

/// Moondream's Parakeet Ultra, the model the macOS app runs, converted to sherpa-onnx's format and
/// quantized to int8 by Plotdesk (CC BY 4.0). Pinned by checksum, so a changed file never loads.
pub const PARAKEET_ULTRA: Model = Model {
    title: "Parakeet Ultra",
    summary: "Fast and accurate in 25 European languages.",
    size: "670 MB",
    directory: "parakeet-ultra-int8",
    files: &[
        ModelFile { name: "encoder.int8.onnx", bytes: 652_282_328, sha256: "21e533084732d6c13892744f31e5d5305c74330b6f8c923a75ba3b3500325694" },
        ModelFile { name: "decoder.int8.onnx", bytes: 11_845_274, sha256: "1fab98fe6c12aded87d2da66272cc9e148d0a0044ce3850a12fe56302ec4a922" },
        ModelFile { name: "joiner.int8.onnx", bytes: 6_355_277, sha256: "8a71aaccfdba3d451775507a889afd2257d2e754463fd81095a8c8f290f924c2" },
        ModelFile { name: "tokens.txt", bytes: 93_939, sha256: "d58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d" },
    ],
};
const DOWNLOAD_URL: &str = "https://github.com/plotdesk/parakeet-ultra-sherpa-onnx/releases/download/v1";

/// How strongly beam search favors a vocabulary term. 3 corrected every term in Speakty's checks
/// without turning ordinary words, such as "speak to" or "versatile", into terms.
const HOTWORDS_SCORE: f32 = 3.0;

impl Model {
    fn path(&self) -> PathBuf {
        identity::models_dir().join(self.directory)
    }

    fn exists(&self) -> bool {
        self.files.iter().all(|file| std::fs::metadata(self.path().join(file.name)).is_ok_and(|m| m.len() == file.bytes))
    }

    fn total_bytes(&self) -> u64 {
        self.files.iter().map(|f| f.bytes).sum()
    }
}

enum Progress {
    Downloaded(f64),
    Loading,
    Ready(Arc<OfflineRecognizer>),
    Failed(String),
}

pub struct Transcriber {
    pub model: &'static Model,
    pub state: Rc<Observable<State>>,
    recognizer: RefCell<Option<Arc<OfflineRecognizer>>>,
    preparing: Cell<bool>,
}

impl Transcriber {
    pub fn new() -> Rc<Self> {
        let model = &PARAKEET_ULTRA;
        Rc::new(Self {
            model,
            state: Observable::new(if model.exists() { State::Loading } else { State::Absent }),
            recognizer: RefCell::default(),
            preparing: Cell::new(false),
        })
    }

    /// Downloads the model if needed and loads it, so the first dictation is as fast as the rest.
    pub fn prepare(self: &Rc<Self>) {
        if self.preparing.get() || self.recognizer.borrow().is_some() {
            return;
        }
        self.preparing.set(true);
        self.state.set(if self.model.exists() { State::Loading } else { State::Downloading(0.0) });
        let (progress, updates) = async_channel::unbounded();
        let model = self.model;
        std::thread::spawn(move || {
            let result = download(model, &progress).and_then(|()| {
                let _ = progress.send_blocking(Progress::Loading);
                load(model)
            });
            let _ = progress.send_blocking(match result {
                Ok(recognizer) => Progress::Ready(Arc::new(recognizer)),
                Err(error) => Progress::Failed(error),
            });
        });
        let this = self.clone();
        gtk::glib::spawn_future_local(async move {
            while let Ok(update) = updates.recv().await {
                match update {
                    Progress::Downloaded(fraction) => this.state.set(State::Downloading(fraction)),
                    Progress::Loading => this.state.set(State::Loading),
                    Progress::Ready(recognizer) => {
                        this.preparing.set(false);
                        *this.recognizer.borrow_mut() = Some(recognizer);
                        this.state.set(State::Ready);
                        log::info!("{} is ready", this.model.title);
                    }
                    Progress::Failed(error) => {
                        this.preparing.set(false);
                        log::error!("Preparing {} failed: {error}", this.model.title);
                        this.state.set(State::Failed(error));
                    }
                }
            }
        });
    }

    /// Deletes the downloaded model. Dictation stays off until it's downloaded again.
    pub fn remove(&self) {
        if self.state.get() != State::Ready {
            return;
        }
        self.recognizer.borrow_mut().take();
        let _ = std::fs::remove_dir_all(self.model.path());
        self.state.set(State::Absent);
    }

    /// The transcript of 16 kHz mono speech, leaning toward the vocabulary's terms.
    pub async fn transcribe(&self, samples: Vec<f32>, vocabulary: Vec<String>) -> Result<String, String> {
        let recognizer = self.recognizer.borrow().clone().ok_or("The model isn't ready")?;
        gtk::gio::spawn_blocking(move || {
            let start = std::time::Instant::now();
            let text = recognize(&recognizer, &samples, &vocabulary);
            log::info!(
                "Transcribed {:.1} s in {:.2} s",
                samples.len() as f64 / SAMPLE_RATE as f64,
                start.elapsed().as_secs_f64()
            );
            text
        })
        .await
        .map_err(|_| "Transcription crashed".to_string())
    }
}

fn recognize(recognizer: &OfflineRecognizer, samples: &[f32], vocabulary: &[String]) -> String {
    // One term per line. A colon would read as a per-term score.
    let hotwords: Vec<String> = vocabulary.iter().map(|t| t.replace(':', " ").trim().to_string()).filter(|t| !t.is_empty()).collect();
    let stream = if hotwords.is_empty() {
        recognizer.create_stream()
    } else {
        recognizer.create_stream_with_hotwords(&hotwords.join("\n"))
    };
    stream.accept_waveform(SAMPLE_RATE as i32, samples);
    recognizer.decode(&stream);
    stream.get_result().map(|r| r.text.trim().to_string()).unwrap_or_default()
}

fn download(model: &Model, progress: &async_channel::Sender<Progress>) -> Result<(), String> {
    if model.exists() {
        return Ok(());
    }
    let directory = model.path();
    std::fs::create_dir_all(&directory).map_err(|e| e.to_string())?;
    let total = model.total_bytes() as f64;
    let mut done = 0u64;
    for file in model.files {
        let path = directory.join(file.name);
        if std::fs::metadata(&path).is_ok_and(|m| m.len() == file.bytes) {
            done += file.bytes;
            continue;
        }
        let partial = directory.join(format!("{}.part", file.name));
        let response = ureq::get(&format!("{DOWNLOAD_URL}/{}", file.name)).call().map_err(|e| e.to_string())?;
        let mut reader = response.into_body().into_reader();
        let mut output = std::fs::File::create(&partial).map_err(|e| e.to_string())?;
        let mut hasher = Sha256::new();
        let mut buffer = vec![0; 1 << 16];
        let mut reported = 0.0;
        loop {
            let count = reader.read(&mut buffer).map_err(|e| e.to_string())?;
            if count == 0 {
                break;
            }
            hasher.update(&buffer[..count]);
            output.write_all(&buffer[..count]).map_err(|e| e.to_string())?;
            done += count as u64;
            let fraction = done as f64 / total;
            if fraction - reported >= 0.005 {
                reported = fraction;
                let _ = progress.send_blocking(Progress::Downloaded(fraction));
            }
        }
        let digest: String = hasher.finalize().iter().map(|b| format!("{b:02x}")).collect();
        if digest != file.sha256 {
            let _ = std::fs::remove_file(&partial);
            return Err(format!("{} doesn't match its checksum", file.name));
        }
        std::fs::rename(&partial, &path).map_err(|e| e.to_string())?;
    }
    Ok(())
}

fn load(model: &Model) -> Result<OfflineRecognizer, String> {
    let directory = model.path();
    let path = |name: &str| Some(directory.join(name).to_string_lossy().into_owned());
    let vocab = directory.join("bpe.vocab");
    if !vocab.exists() {
        write_bpe_vocab(&directory.join("tokens.txt"), &vocab).map_err(|e| e.to_string())?;
    }
    let mut config = OfflineRecognizerConfig::default();
    config.feat_config.feature_dim = 128;
    config.model_config.transducer.encoder = path("encoder.int8.onnx");
    config.model_config.transducer.decoder = path("decoder.int8.onnx");
    config.model_config.transducer.joiner = path("joiner.int8.onnx");
    config.model_config.tokens = path("tokens.txt");
    config.model_config.model_type = Some("nemo_transducer".into());
    // Physical cores: the encoder gains nothing from hyperthreads.
    let threads = std::thread::available_parallelism().map_or(4, |n| n.get() / 2).clamp(1, 8);
    config.model_config.num_threads = threads as i32;
    // Hotwords need beam search and the BPE vocabulary to spell them in tokens.
    config.decoding_method = Some("modified_beam_search".into());
    config.model_config.modeling_unit = Some("bpe".into());
    config.model_config.bpe_vocab = Some(vocab.to_string_lossy().into_owned());
    config.hotwords_score = HOTWORDS_SCORE;
    let recognizer = OfflineRecognizer::create(&config).ok_or("sherpa-onnx couldn't load the model")?;
    // A short transcription warms up the encoder, so the first dictation doesn't pay for it.
    recognize(&recognizer, &vec![0.0; SAMPLE_RATE], &[]);
    Ok(recognizer)
}

/// sherpa-onnx spells hotwords with a sentencepiece vocabulary, which the export doesn't include.
/// The token IDs are the BPE model's, so tokens.txt gives the pieces in order, and the score only has
/// to rank them.
fn write_bpe_vocab(tokens: &std::path::Path, vocab: &std::path::Path) -> std::io::Result<()> {
    let lines: String = std::fs::read_to_string(tokens)?
        .lines()
        .filter_map(|line| line.rsplit_once(' '))
        .map(|(piece, id)| format!("{piece}\t-{id}\n"))
        .collect();
    std::fs::write(vocab, lines)
}
