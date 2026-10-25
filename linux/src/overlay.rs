//! Shows the recording display while a dictation runs: a layer-shell surface above every window,
//! at the bottom or top of the focused output. It takes no keyboard focus and no clicks, so typing
//! goes on in the app underneath. The styles match the macOS app's, drawn with cairo.

use crate::dictation::Phase;
use crate::preferences::{OverlayPosition, OverlayStyle, Recording};
use crate::recorder::Recorder;
use gtk::cairo::Context;
use gtk::prelude::*;
use gtk4_layer_shell::{Edge, KeyboardMode, Layer, LayerShell};
use std::cell::{Cell, RefCell};
use std::f64::consts::{PI, TAU};
use std::rc::Rc;
use std::time::Instant;

/// The size of every style at 100%. The capsules fill it; the orb is as tall and as wide as tall.
const SIZE: (f64, f64) = (73.0, 28.0);
/// Room around the display for its shadow and the orb's glow, at every size.
const MARGIN: f64 = 24.0;
const FADE: f64 = 0.15;
/// How long the capsules take to swap the level bars for the spinner.
const STATE_CHANGE: f64 = 0.2;

struct Model {
    recording: Recording,
    transcribing_since: Option<Instant>,
    shown: bool,
    /// When the last fade started, and the opacity it started from.
    fade: (Instant, f64),
    /// Smoothed from the recorder, as the macOS meter samples it.
    level: f32,
}

pub struct Overlay {
    window: gtk::Window,
    area: gtk::DrawingArea,
    model: Rc<RefCell<Model>>,
    ticking: Rc<Cell<bool>>,
    recorder: Recorder,
}

impl Overlay {
    pub fn new(application: &adw::Application, recorder: Recorder) -> Rc<Self> {
        let window = gtk::Window::builder().application(application).decorated(false).resizable(false).build();
        window.add_css_class("speakty-overlay");
        window.init_layer_shell();
        window.set_layer(Layer::Overlay);
        window.set_namespace(Some("speakty"));
        window.set_keyboard_mode(KeyboardMode::None);
        let area = gtk::DrawingArea::new();
        window.set_child(Some(&area));
        // Clicks pass through to the window below.
        window.connect_realize(|window| {
            if let Some(surface) = window.surface() {
                surface.set_input_region(Some(&gtk::cairo::Region::create()));
            }
        });
        let css = gtk::CssProvider::new();
        css.load_from_string("window.speakty-overlay { background: transparent; }");
        gtk::style_context_add_provider_for_display(&gtk::prelude::WidgetExt::display(&window), &css, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION);

        let model = Rc::new(RefCell::new(Model {
            recording: Recording::default(),
            transcribing_since: None,
            shown: false,
            fade: (Instant::now(), 0.0),
            level: 0.0,
        }));
        let draw_model = model.clone();
        let start = Instant::now();
        area.set_draw_func(move |_, cr, width, height| {
            let model = draw_model.borrow();
            draw(cr, &model, width as f64, height as f64, start.elapsed().as_secs_f64());
        });
        Rc::new(Self { window, area, model, ticking: Rc::default(), recorder })
    }

    pub fn update(self: &Rc<Self>, phase: Phase, recording: &Recording) {
        {
            let mut model = self.model.borrow_mut();
            model.recording = recording.clone();
        }
        match phase {
            Phase::Idle => self.hide(),
            Phase::Recording(_) => {
                self.model.borrow_mut().transcribing_since = None;
                self.show();
            }
            Phase::Transcribing => {
                self.model.borrow_mut().transcribing_since.get_or_insert(Instant::now());
            }
        }
    }

    fn show(self: &Rc<Self>) {
        let recording = self.model.borrow().recording.clone();
        let max = *Recording::SCALE_RANGE.end();
        self.window.set_default_size((SIZE.0 * max + 2.0 * MARGIN) as i32, (SIZE.1 * max + 2.0 * MARGIN) as i32);
        let edge = if recording.position == OverlayPosition::Bottom { Edge::Bottom } else { Edge::Top };
        let other = if edge == Edge::Bottom { Edge::Top } else { Edge::Bottom };
        self.window.set_anchor(edge, true);
        self.window.set_anchor(other, false);
        // The margin around the display may reach past the edge, which a layer surface can't, so a
        // display nearer than the margin moves inside the surface instead.
        self.window.set_margin(edge, (recording.edge_distance - MARGIN).max(0.0) as i32);
        self.window.set_margin(other, 0);
        let mut model = self.model.borrow_mut();
        if !model.shown {
            let opacity = self.current_opacity(&model);
            model.fade = (Instant::now(), opacity);
            model.shown = true;
        }
        drop(model);
        self.window.set_visible(true);
        self.start_ticking();
    }

    fn hide(self: &Rc<Self>) {
        let mut model = self.model.borrow_mut();
        if !model.shown {
            return;
        }
        let opacity = self.current_opacity(&model);
        model.fade = (Instant::now(), opacity);
        model.shown = false;
    }

    fn current_opacity(&self, model: &Model) -> f64 {
        let progress = (model.fade.0.elapsed().as_secs_f64() / FADE).min(1.0);
        let target = if model.shown { 1.0 } else { 0.0 };
        model.fade.1 + (target - model.fade.1) * progress
    }

    /// Redraws every frame while shown or fading, and stops once hidden.
    fn start_ticking(self: &Rc<Self>) {
        if self.ticking.replace(true) {
            return;
        }
        let this = self.clone();
        self.area.add_tick_callback(move |area, _| {
            let mut model = this.model.borrow_mut();
            let level = this.recorder.level();
            model.level = if model.transcribing_since.is_some() { model.level } else { level };
            let opacity = this.current_opacity(&model);
            let hidden = !model.shown && opacity <= 0.0;
            drop(model);
            this.window.set_opacity(opacity);
            area.queue_draw();
            if hidden {
                this.window.set_visible(false);
                this.ticking.set(false);
                return gtk::glib::ControlFlow::Break;
            }
            gtk::glib::ControlFlow::Continue
        });
    }
}

/// How far a part of a style moves for the voice level, from 0 to 1: up to the level, pulsing at its
/// own phase so a steady voice still looks alive.
fn swing(level: f32, time: f64, phase: f64) -> f64 {
    level as f64 * (0.5 + 0.5 * (time * 4.6 + phase).sin().abs())
}

fn draw(cr: &Context, model: &Model, width: f64, height: f64, time: f64) {
    let recording = &model.recording;
    let scale = recording.scale;
    let (w, h) = match recording.style {
        OverlayStyle::Dark => (SIZE.0 * scale, SIZE.1 * scale),
        OverlayStyle::Orb => (SIZE.1 * scale, SIZE.1 * scale),
    };
    // The display sits the edge distance from the screen edge; the surface's margin covers what it can.
    let inset = MARGIN.min(recording.edge_distance);
    let x = (width - w) / 2.0;
    let y = match recording.position {
        OverlayPosition::Bottom => height - inset - h,
        OverlayPosition::Top => inset,
    };
    let transcribing = model.transcribing_since.map(|since| since.elapsed().as_secs_f64());
    match recording.style {
        OverlayStyle::Dark => draw_capsule(cr, x, y, w, h, scale, model.level, time, transcribing),
        OverlayStyle::Orb => draw_orb(cr, x + w / 2.0, y + h / 2.0, h / 2.0, model.level, time, transcribing.is_some()),
    }
}

fn capsule_path(cr: &Context, x: f64, y: f64, w: f64, h: f64) {
    let r = h / 2.0;
    cr.new_sub_path();
    cr.arc(x + w - r, y + r, r, -PI / 2.0, PI / 2.0);
    cr.arc(x + r, y + r, r, PI / 2.0, 3.0 * PI / 2.0);
    cr.close_path();
}

/// The dark island capsule, with level bars while listening and a spinner while transcribing.
#[allow(clippy::too_many_arguments)]
fn draw_capsule(cr: &Context, x: f64, y: f64, w: f64, h: f64, scale: f64, level: f32, time: f64, transcribing: Option<f64>) {
    // A soft shadow, 2 px down, from layered translucent capsules.
    for i in (1..=6).rev() {
        let spread = i as f64;
        capsule_path(cr, x - spread, y - spread + 2.0, w + 2.0 * spread, h + 2.0 * spread);
        cr.set_source_rgba(0.0, 0.0, 0.0, 0.35 / 6.0 * (1.0 - spread / 7.0));
        let _ = cr.fill();
    }
    capsule_path(cr, x, y, w, h);
    cr.set_source_rgba(0.12, 0.12, 0.12, 0.9);
    let _ = cr.fill_preserve();
    cr.set_source_rgba(1.0, 1.0, 1.0, 0.16);
    cr.set_line_width(0.5);
    let _ = cr.stroke();

    // The bars shrink and fade into the spinner, which grows in.
    let change = transcribing.map_or(0.0, |t| (t / STATE_CHANGE).min(1.0));
    let (cx, cy) = (x + w / 2.0, y + h / 2.0);
    if change < 1.0 {
        let fade = 1.0 - change;
        cr.save().ok();
        cr.translate(cx, cy);
        cr.scale(0.5 + 0.5 * fade, 0.5 + 0.5 * fade);
        cr.set_source_rgba(0.96, 0.96, 0.96, fade);
        let count = 9;
        let (bar, spacing) = (3.0 * scale, 3.0 * scale);
        let total = count as f64 * bar + (count - 1) as f64 * spacing;
        for index in 0..count {
            let i = index as f64;
            let center = 1.0 - (i - (count - 1) as f64 / 2.0).abs() / 6.0;
            let height = (3.0 + 13.0 * center * swing(level, time, i * 1.7)) * scale;
            let left = -total / 2.0 + i * (bar + spacing);
            let r = bar / 2.0;
            cr.new_sub_path();
            cr.arc(left + r, -height / 2.0 + r, r, PI, 2.0 * PI);
            cr.arc(left + r, height / 2.0 - r, r, 0.0, PI);
            cr.close_path();
            let _ = cr.fill();
        }
        cr.restore().ok();
    }
    if change > 0.0 {
        // A plain open arc turning a little faster than once a second, muted like a control that's off.
        cr.save().ok();
        cr.translate(cx, cy);
        cr.scale(0.5 + 0.5 * change, 0.5 + 0.5 * change);
        cr.rotate((time % 0.9) / 0.9 * TAU);
        cr.set_source_rgba(0.96, 0.96, 0.96, 0.5 * change);
        cr.set_line_width(1.75 * scale);
        cr.set_line_cap(gtk::cairo::LineCap::Round);
        cr.arc(0.0, 0.0, 5.25 * scale - 0.875 * scale, -PI / 2.0, -PI / 2.0 + 0.75 * TAU);
        let _ = cr.stroke();
        cr.restore().ok();
    }
}

/// The orb's ring, after the system accent hues, as (position, r, g, b).
const ORB_COLORS: [(f64, f64, f64, f64); 6] = [
    (0.0, 0.04, 0.52, 1.0),
    (0.2, 0.37, 0.36, 0.9),
    (0.4, 0.75, 0.35, 0.95),
    (0.6, 1.0, 0.22, 0.37),
    (0.8, 1.0, 0.62, 0.04),
    (1.0, 0.04, 0.52, 1.0),
];

fn orb_color(position: f64) -> (f64, f64, f64) {
    let p = position.rem_euclid(1.0);
    let pair = ORB_COLORS.windows(2).find(|pair| p <= pair[1].0).unwrap_or(&ORB_COLORS[4..6]);
    let t = (p - pair[0].0) / (pair[1].0 - pair[0].0);
    let mix = |a: f64, b: f64| a + (b - a) * t;
    (mix(pair[0].1, pair[1].1), mix(pair[0].2, pair[1].2), mix(pair[0].3, pair[1].3))
}

/// A glowing ring that breathes with the voice, and turns quickly while transcribing.
fn draw_orb(cr: &Context, cx: f64, cy: f64, radius: f64, level: f32, time: f64, transcribing: bool) {
    let swing = if transcribing { 0.0 } else { swing(level, time, 0.0) };
    let glow = if transcribing { 0.45 } else { 0.2 + 0.7 * swing };
    let angle = (time * if transcribing { 180.0 } else { 24.0 }).to_radians();
    let radius = radius * (1.0 + 0.18 * swing);
    // A ring of `width` centered on the circle at `at`, its color turning with the angle.
    let ring = |at: f64, width: f64, alpha: f64| {
        let segments = 96;
        for s in 0..segments {
            let start = s as f64 / segments as f64;
            let (r, g, b) = orb_color(start);
            cr.set_source_rgba(r, g, b, alpha);
            cr.set_line_width(width);
            let a0 = angle + start * TAU - PI / 2.0;
            cr.arc(cx, cy, at, a0, a0 + TAU / segments as f64 + 0.02);
            let _ = cr.stroke();
        }
    };
    // The glow spills past the ring, into the surface's margin.
    for spread in [7.0, 4.5, 2.5] {
        ring(radius, 2.0 * spread, glow * 0.3);
    }
    ring(radius / 2.0, radius, 1.0);
    cr.arc(cx, cy, radius - 2.75, 0.0, TAU);
    cr.set_source_rgba(0.09, 0.09, 0.09, 0.88);
    let _ = cr.fill();
}
