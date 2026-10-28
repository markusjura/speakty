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
use std::cell::{Cell, RefCell};
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
    Start { target: Option<String>, started: async_channel::Sender<Result<(), String>> },
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
    /// The result arrives once the microphone is live, or with the error that kept it from starting.
    pub fn start(&self, target: Option<String>) -> async_channel::Receiver<Result<(), String>> {
        let (started, result) = async_channel::bounded(1);
        if self.commands.send(Command::Start { target, started }).is_err() {
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
struct Active {
    stream: pw::stream::StreamRc,
    _listener: pw::stream::StreamListener<Format>,
}

/// A node a recording can come from.
struct Node {
    id: u32,
    source: Source,
    /// Whether Settings offers it as a microphone.
    offered: bool,
    channels: Rc<Cell<Option<u32>>>,
    _proxy: pw::node::Node,
    _listener: pw::node::NodeListener,
}

/// The channels of the source PipeWire will record: the target while it's there, else the default input.
fn source_channels(nodes: &[Node], target: Option<&str>, default: Option<&str>) -> Option<u32> {
    let find = |name: &str| nodes.iter().find(|node| node.source.name == name);
    target.and_then(find).or_else(|| default.and_then(find))?.channels.get()
}

fn offered(nodes: &[Node]) -> Vec<Source> {
    nodes.iter().filter(|node| node.offered).map(|node| node.source.clone()).collect()
}

/// A node's channels, from its channel count, or else its positions, such as "FL,FR" or "[ AUX0 AUX1 ]".
fn channel_count(channels: Option<&str>, positions: Option<&str>) -> Option<u32> {
    channels.and_then(|channels| channels.parse().ok()).or_else(|| {
        let count = positions?.split(|c: char| c == ',' || c == '[' || c == ']' || c.is_whitespace()).filter(|p| !p.is_empty()).count();
        (count > 0).then_some(count as u32)
    })
}

#[derive(Default)]
struct Format {
    channels: u32,
    started: Option<async_channel::Sender<Result<(), String>>>,
}

fn run(receiver: pw::channel::Receiver<Command>, capture: Arc<Mutex<Capture>>, sources: Arc<Mutex<Vec<Source>>>) -> Result<(), pw::Error> {
    pw::init();
    let mainloop = pw::main_loop::MainLoopRc::new(None)?;
    let context = pw::context::ContextRc::new(&mainloop, None)?;
    let core = context.connect_rc(None)?;

    let registry = core.get_registry_rc()?;
    let nodes: Rc<RefCell<Vec<Node>>> = Rc::default();
    // The default input's name, which the "default" metadata object carries as JSON.
    let default_source: Rc<RefCell<Option<String>>> = Rc::default();
    let metadata: Rc<RefCell<Option<(pw::metadata::Metadata, pw::metadata::MetadataListener)>>> = Rc::default();
    let (added, removed) = ((nodes.clone(), sources.clone()), (nodes.clone(), sources.clone()));
    let (bound, default) = (registry.clone(), default_source.clone());
    let _registry_listener = registry
        .add_listener_local()
        .global(move |global| {
            let Some(props) = global.props else { return };
            if global.type_ == pw::types::ObjectType::Metadata && props.get("metadata.name") == Some("default") {
                let Ok(proxy) = bound.bind::<pw::metadata::Metadata, _>(global) else { return };
                let default = default.clone();
                let listener = proxy
                    .add_listener_local()
                    .property(move |_, key, _, value| {
                        if key.is_none_or(|key| key == "default.audio.source") {
                            let value: Option<serde_json::Value> = value.and_then(|value| serde_json::from_str(value).ok());
                            *default.borrow_mut() = value.and_then(|value| value["name"].as_str().map(str::to_string));
                        }
                        0
                    })
                    .register();
                *metadata.borrow_mut() = Some((proxy, listener));
                return;
            }
            // Settings offers microphones. A recording can also target a virtual source or a
            // duplex node, such as the one scripts/dictate.sh plays into.
            let class = props.get("media.class").unwrap_or_default();
            if !matches!(class, "Audio/Source" | "Audio/Source/Virtual" | "Audio/Duplex") {
                return;
            }
            let name = props.get("node.name").unwrap_or_default().to_string();
            let description = props.get("node.description").or(props.get("node.nick")).unwrap_or(&name).to_string();
            // The channels come with the node's info, which only a proxy receives.
            let Ok(proxy) = bound.bind::<pw::node::Node, _>(global) else { return };
            let channels: Rc<Cell<Option<u32>>> = Rc::default();
            let info_channels = channels.clone();
            let listener = proxy
                .add_listener_local()
                .info(move |info| {
                    if let Some(count) = info.props().and_then(|props| channel_count(props.get("audio.channels"), props.get("audio.position"))) {
                        info_channels.set(Some(count));
                    }
                })
                .register();
            let source = Source { name, description };
            added.0.borrow_mut().push(Node { id: global.id, source, offered: class == "Audio/Source", channels, _proxy: proxy, _listener: listener });
            *added.1.lock().unwrap() = offered(&added.0.borrow());
        })
        .global_remove(move |id| {
            removed.0.borrow_mut().retain(|node| node.id != id);
            *removed.1.lock().unwrap() = offered(&removed.0.borrow());
        })
        .register();

    let active: Rc<RefCell<Option<Active>>> = Rc::default();
    let _receiver = receiver.attach(mainloop.loop_(), move |command| match command {
        Command::Start { target, started } => {
            stop(&active);
            *capture.lock().unwrap() = Capture::default();
            let channels = source_channels(&nodes.borrow(), target.as_deref(), default_source.borrow().as_deref());
            match open_stream(&core, target, channels, capture.clone(), started.clone()) {
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
    if let Some(Active { stream, .. }) = active.borrow_mut().take() {
        let _ = stream.disconnect();
    }
}

/// Records from `target` with the source's `channels`, so mono() picks the voice from them. With
/// the count unknown, PipeWire mixes the source to stereo.
fn open_stream(
    core: &pw::core::CoreRc,
    target: Option<String>,
    channels: Option<u32>,
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
    if channels.is_some() {
        // Links the source's channels one to one, in order, rather than mixing them.
        props.insert(*pw::keys::STREAM_DONT_REMIX, "true");
    }
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
            // The offset counts around the buffer, which holds no more than its own length.
            let start = if bytes.is_empty() { 0 } else { offset % bytes.len() };
            let samples: Vec<f32> = bytes[start..(start + size).min(bytes.len())]
                .chunks_exact(4)
                .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
                .collect();
            capture.lock().unwrap().append(&mono(&samples, format.channels.max(1) as usize));
        })
        .register()
        .map_err(|e| e.to_string())?;

    // F32 at 16 kHz, which PipeWire converts to.
    let mut info = spa::param::audio::AudioInfoRaw::new();
    info.set_format(spa::param::audio::AudioFormat::F32LE);
    info.set_rate(SAMPLE_RATE as u32);
    if let Some(channels) = channels {
        info.set_channels(channels);
    }
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
    Ok(Active { stream, _listener: listener })
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counts_channels_from_either_property() {
        assert_eq!(channel_count(Some("4"), Some("FL,FR")), Some(4));
        assert_eq!(channel_count(None, Some("FL,FR")), Some(2));
        assert_eq!(channel_count(None, Some("[ AUX0 AUX1 AUX2 AUX3 ]")), Some(4));
        assert_eq!(channel_count(None, None), None);
    }
}
