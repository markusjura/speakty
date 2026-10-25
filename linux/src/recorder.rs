//! Records the microphone as 16 kHz mono samples, the format Parakeet takes, and meters the voice
//! level for the recording display. A fresh PipeWire stream per recording keeps the microphone off
//! between dictations and picks up the chosen input every time.
//!
//! PipeWire runs on a thread of its own, as the audio engine has its own queue on macOS: starting an
//! interface can take half a second, which on the main thread would hold up the key events that tell
//! a tap from a hold. Commands queue up in the order they're sent, so a stop or cancel always follows
//! the start it belongs to.

use crate::transcript::SAMPLE_RATE;
use pipewire as pw;
use pw::spa;
use std::cell::RefCell;
use std::rc::Rc;
use std::sync::{Arc, Mutex};

/// A microphone PipeWire offers.
#[derive(Clone, Debug, PartialEq)]
pub struct Source {
    /// The stable node name, which preferences store.
    pub name: String,
    pub description: String,
}

/// The samples and level of the recording in progress, shared between the audio and main threads.
#[derive(Default)]
struct Capture {
    samples: Vec<f32>,
    level: f32,
}

impl Capture {
    /// Appends a chunk and moves the level toward its loudness: quickly up, slowly down, as meters do.
    fn append(&mut self, chunk: &[f32]) {
        if chunk.is_empty() {
            return;
        }
        let rms = (chunk.iter().map(|s| s * s).sum::<f32>() / chunk.len() as f32).sqrt();
        // -50 dB is silence and -10 dB a loud voice.
        let loudness = ((20.0 * rms.max(1e-6).log10() + 50.0) / 40.0).clamp(0.0, 1.0);
        self.samples.extend_from_slice(chunk);
        self.level = if loudness > self.level { loudness } else { self.level * 0.7 + loudness * 0.3 };
    }
}

enum Command {
    Start { target: Option<String>, test_audio: Option<String>, started: async_channel::Sender<Result<(), String>> },
    Stop { samples: async_channel::Sender<Vec<f32>> },
    Cancel,
}

#[derive(Clone)]
pub struct Recorder {
    commands: pw::channel::Sender<Command>,
    capture: Arc<Mutex<Capture>>,
    sources: Arc<Mutex<Vec<Source>>>,
}

impl Recorder {
    pub fn new() -> Self {
        let (commands, receiver) = pw::channel::channel();
        let capture: Arc<Mutex<Capture>> = Arc::default();
        let sources: Arc<Mutex<Vec<Source>>> = Arc::default();
        let (thread_capture, thread_sources) = (capture.clone(), sources.clone());
        std::thread::Builder::new()
            .name("pipewire".into())
            .spawn(move || {
                if let Err(error) = run(receiver, thread_capture, thread_sources) {
                    log::error!("PipeWire stopped: {error}");
                }
            })
            .expect("PipeWire thread");
        Self { commands, capture, sources }
    }

    /// The voice level in 0...1, for drawing.
    pub fn level(&self) -> f32 {
        self.capture.lock().unwrap().level
    }

    /// The microphones PipeWire offers now.
    pub fn sources(&self) -> Vec<Source> {
        self.sources.lock().unwrap().clone()
    }

    /// Starts recording from the source named `target`, or the default input when it's None or gone.
    /// Speakty Dev replays `test_audio` instead when it's set. The result arrives once the microphone
    /// is live, or with the error that kept it from starting.
    pub fn start(&self, target: Option<String>, test_audio: Option<String>) -> async_channel::Receiver<Result<(), String>> {
        let (started, result) = async_channel::bounded(1);
        if self.commands.send(Command::Start { target, test_audio, started }).is_err() {
            log::error!("PipeWire isn't running");
        }
        result
    }

    /// Stops and returns everything recorded since `start`.
    pub async fn stop(&self) -> Vec<f32> {
        let (samples, result) = async_channel::bounded(1);
        if self.commands.send(Command::Stop { samples }).is_err() {
            return Vec::new();
        }
        // Without an answer PipeWire isn't running, and there's nothing to wait for.
        gtk::glib::future_with_timeout(std::time::Duration::from_secs(2), result.recv()).await.ok().and_then(Result::ok).unwrap_or_default()
    }

    pub fn cancel(&self) {
        let _ = self.commands.send(Command::Cancel);
    }
}

/// The recording in progress, kept alive on the PipeWire thread.
enum Active {
    Stream { stream: pw::stream::StreamRc, _listener: pw::stream::StreamListener<Format> },
    /// Replays a test file with a timer, as the microphone would deliver it.
    Replay { _timer: pw::loop_::TimerSource<'static> },
}

#[derive(Default)]
struct Format {
    channels: u32,
    started: Option<async_channel::Sender<Result<(), String>>>,
}

fn run(receiver: pw::channel::Receiver<Command>, capture: Arc<Mutex<Capture>>, sources: Arc<Mutex<Vec<Source>>>) -> Result<(), pw::Error> {
    pw::init();
    // Leaked, so the loop, context, and core live as long as the thread, which is as long as Speakty.
    let mainloop: &'static pw::main_loop::MainLoopRc = Box::leak(Box::new(pw::main_loop::MainLoopRc::new(None)?));
    let context = pw::context::ContextRc::new(mainloop, None)?;
    let core = context.connect_rc(None)?;

    let registry = core.get_registry_rc()?;
    let nodes: Rc<RefCell<Vec<(u32, Source)>>> = Rc::default();
    let (added, removed) = ((nodes.clone(), sources.clone()), (nodes.clone(), sources.clone()));
    let _registry_listener = registry
        .add_listener_local()
        .global(move |global| {
            let Some(props) = global.props else { return };
            if props.get("media.class") != Some("Audio/Source") {
                return;
            }
            let name = props.get("node.name").unwrap_or_default().to_string();
            let description = props.get("node.description").or(props.get("node.nick")).unwrap_or(&name).to_string();
            added.0.borrow_mut().push((global.id, Source { name, description }));
            *added.1.lock().unwrap() = added.0.borrow().iter().map(|(_, s)| s.clone()).collect();
        })
        .global_remove(move |id| {
            removed.0.borrow_mut().retain(|(node, _)| *node != id);
            *removed.1.lock().unwrap() = removed.0.borrow().iter().map(|(_, s)| s.clone()).collect();
        })
        .register();

    let active: Rc<RefCell<Option<Active>>> = Rc::default();
    let _receiver = receiver.attach(mainloop.loop_(), move |command| match command {
        Command::Start { target, test_audio, started } => {
            active.borrow_mut().take();
            *capture.lock().unwrap() = Capture::default();
            let result = match test_audio {
                Some(path) => replay(mainloop, &path, capture.clone()).map(|timer| {
                    let _ = started.try_send(Ok(()));
                    Active::Replay { _timer: timer }
                }),
                None => open_stream(&core, target, capture.clone(), started.clone()),
            };
            match result {
                Ok(recording) => *active.borrow_mut() = Some(recording),
                Err(error) => {
                    let _ = started.try_send(Err(error));
                }
            }
        }
        Command::Stop { samples } => {
            stop(&active);
            let _ = samples.try_send(std::mem::take(&mut *capture.lock().unwrap()).samples);
        }
        Command::Cancel => {
            stop(&active);
            *capture.lock().unwrap() = Capture::default();
        }
    });
    mainloop.run();
    Ok(())
}

fn stop(active: &RefCell<Option<Active>>) {
    if let Some(Active::Stream { stream, .. }) = active.borrow_mut().take() {
        let _ = stream.disconnect();
    }
}

fn open_stream(
    core: &pw::core::CoreRc,
    target: Option<String>,
    capture: Arc<Mutex<Capture>>,
    started: async_channel::Sender<Result<(), String>>,
) -> Result<Active, String> {
    let mut props = pw::properties::properties! {
        *pw::keys::MEDIA_TYPE => "Audio",
        *pw::keys::MEDIA_CATEGORY => "Capture",
        *pw::keys::MEDIA_ROLE => "Communication",
        *pw::keys::APP_NAME => crate::identity::NAME,
        *pw::keys::NODE_NAME => "speakty",
    };
    if let Some(target) = target {
        // A source that's gone falls back to the default input.
        props.insert("target.object", target);
    }
    let stream = pw::stream::StreamRc::new(core.clone(), "Dictation", props).map_err(|e| e.to_string())?;
    let listener = stream
        .add_local_listener_with_user_data(Format { channels: 0, started: Some(started) })
        .state_changed(|_, format, _, state| match state {
            pw::stream::StreamState::Streaming => {
                if let Some(started) = format.started.take() {
                    let _ = started.try_send(Ok(()));
                }
            }
            pw::stream::StreamState::Error(error) => {
                if let Some(started) = format.started.take() {
                    let _ = started.try_send(Err(error));
                }
            }
            _ => {}
        })
        .param_changed(|_, format, id, param| {
            let Some(param) = param else { return };
            if id != spa::param::ParamType::Format.as_raw() {
                return;
            }
            let mut info = spa::param::audio::AudioInfoRaw::new();
            if info.parse(param).is_ok() {
                format.channels = info.channels();
                log::info!("Recording at {} Hz, {} channels", info.rate(), info.channels());
            }
        })
        .process(move |stream, format| {
            let Some(mut buffer) = stream.dequeue_buffer() else { return };
            let Some(data) = buffer.datas_mut().first_mut() else { return };
            let (offset, size) = (data.chunk().offset() as usize, data.chunk().size() as usize);
            let Some(bytes) = data.data() else { return };
            let start = offset.min(bytes.len());
            let samples: Vec<f32> = bytes[start..(start + size).min(bytes.len())]
                .chunks_exact(4)
                .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
                .collect();
            capture.lock().unwrap().append(&mono(&samples, format.channels.max(1) as usize));
        })
        .register()
        .map_err(|e| e.to_string())?;

    // F32 at 16 kHz, which PipeWire converts to. The channels stay the device's, so mono() can pick them.
    let mut info = spa::param::audio::AudioInfoRaw::new();
    info.set_format(spa::param::audio::AudioFormat::F32LE);
    info.set_rate(SAMPLE_RATE as u32);
    let object = spa::pod::Object {
        type_: spa::utils::SpaTypes::ObjectParamFormat.as_raw(),
        id: spa::param::ParamType::EnumFormat.as_raw(),
        properties: info.into(),
    };
    let bytes = spa::pod::serialize::PodSerializer::serialize(std::io::Cursor::new(Vec::new()), &spa::pod::Value::Object(object))
        .map_err(|e| format!("{e:?}"))?
        .0
        .into_inner();
    let mut params = [spa::pod::Pod::from_bytes(&bytes).ok_or("Invalid format")?];
    stream
        .connect(
            spa::utils::Direction::Input,
            None,
            pw::stream::StreamFlags::AUTOCONNECT | pw::stream::StreamFlags::MAP_BUFFERS,
            &mut params,
        )
        .map_err(|e| e.to_string())?;
    Ok(Active::Stream { stream, _listener: listener })
}

/// Mixes interleaved frames to mono. Mono and stereo devices mix every channel. Interfaces with
/// more, such as the Vocaster's, carry the voice mix on channel 1 and separate sources and loopbacks
/// on the rest, so they record channel 1 alone, as on macOS.
fn mono(samples: &[f32], channels: usize) -> Vec<f32> {
    match channels {
        1 => samples.to_vec(),
        2 => samples.chunks_exact(2).map(|f| (f[0] + f[1]) / 2.0).collect(),
        _ => samples.chunks_exact(channels).map(|f| f[0]).collect(),
    }
}

/// Feeds a WAV file in 50 ms chunks, in real time, so the level moves and a short hold records only the start.
fn replay(mainloop: &'static pw::main_loop::MainLoopRc, path: &str, capture: Arc<Mutex<Capture>>) -> Result<pw::loop_::TimerSource<'static>, String> {
    let samples = read_wav(path)?;
    let chunks: RefCell<std::vec::IntoIter<Vec<f32>>> =
        RefCell::new(samples.chunks(SAMPLE_RATE / 20).map(<[f32]>::to_vec).collect::<Vec<_>>().into_iter());
    let timer = mainloop.loop_().add_timer(move |_| {
        if let Some(chunk) = chunks.borrow_mut().next() {
            capture.lock().unwrap().append(&chunk);
        }
    });
    let period = std::time::Duration::from_millis(50);
    timer.update_timer(Some(period), Some(period)).into_result().map_err(|e| e.to_string())?;
    log::info!("Replaying {path}");
    Ok(timer)
}

/// 16 kHz samples of a WAV file, mixed to mono.
pub fn read_wav(path: &str) -> Result<Vec<f32>, String> {
    let mut reader = hound::WavReader::open(path).map_err(|e| format!("{path}: {e}"))?;
    let spec = reader.spec();
    let samples: Vec<f32> = match spec.sample_format {
        hound::SampleFormat::Float => reader.samples::<f32>().filter_map(Result::ok).collect(),
        hound::SampleFormat::Int => {
            let scale = (1u64 << (spec.bits_per_sample - 1)) as f32;
            reader.samples::<i32>().filter_map(Result::ok).map(|s| s as f32 / scale).collect()
        }
    };
    let mono = mono(&samples, spec.channels as usize);
    if spec.sample_rate as usize == SAMPLE_RATE {
        return Ok(mono);
    }
    // Linear resampling is plenty for test recordings.
    let ratio = spec.sample_rate as f64 / SAMPLE_RATE as f64;
    let count = (mono.len() as f64 / ratio) as usize;
    Ok((0..count)
        .map(|i| {
            let position = i as f64 * ratio;
            let (index, fraction) = (position as usize, (position.fract()) as f32);
            let next = mono.get(index + 1).copied().unwrap_or(mono[index]);
            mono[index] * (1.0 - fraction) + next * fraction
        })
        .collect())
}
