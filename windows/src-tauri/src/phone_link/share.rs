//! Nyeko: one mouse and keyboard for a Mac and this PC (docs/SHARED_MOUSE.md).
//!
//! The Mac connects to this PC's phone link on the local network like a phone does (TLS, this PC's certificate pinned,
//! its token) and asks for `share`, then says where the PC stands (`{type:"share", side:"left"}`: the PC is on the
//! Mac's left). The phone sets it up: it asks this PC for its link (`shareOffer`, nyeko.rs) and hands it to the Mac.
//!
//!   * away: this PC's pointer is pushed off the edge facing the Mac. It says `shareEnter` (at which height), parks
//!     its pointer, and sends its mouse and keyboard to the Mac as `input` lines, caught by low-level hooks, until the
//!     Mac says `shareLeave` (the Mac's pointer came back across);
//!   * guest: the Mac's pointer came across (`shareEnter`). Its `input` is posted here, at absolute positions this side
//!     keeps, until the pointer is pushed back off the edge facing the Mac: `shareLeave`. Touching this PC's own mouse
//!     meanwhile takes the PC back.
//!
//! Both sides ping every 2 s; 7 s of silence while one drives the other gives each its own mouse and keyboard back.
//! Keys travel by name (the Mac's keyCodes, remote_input.rs's vk). Modifiers become the other computer's habits:
//! Ctrl here is ⌘ on the Mac (Ctrl+C copies there too), Win is ⌃, Alt is ⌥; the Mac's ⌘ and ⌃ are Ctrl here.

// The hooks that use most of this exist only on Windows.
#![cfg_attr(not(windows), allow(dead_code))]

use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU64, AtomicU8, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use tokio::sync::mpsc;

use super::hub::Out;

/// The lines a sharing Mac sends (on a connection that asked for `share`).
pub fn handles(t: &str) -> bool {
    matches!(t, "share" | "shareEnter" | "shareLeave" | "input" | "pong")
}

/// Whether this computer can share its mouse (Windows; Linux not yet).
pub fn supported() -> bool {
    cfg!(windows)
}

/// Where the Mac is, seen from this PC.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Side {
    Left,
    Right,
}

impl Side {
    /// The Mac names where the PC stands: "left" of the Mac means the Mac is on the PC's right.
    pub fn of_mac(pc_side: &str) -> Option<Side> {
        match pc_side {
            "left" => Some(Side::Right),
            "right" => Some(Side::Left),
            _ => None,
        }
    }
}

/// This PC's screens as one rectangle (the virtual screen), in pixels.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Screen {
    pub left: i32,
    pub top: i32,
    pub width: i32,
    pub height: i32,
}

impl Screen {
    fn right(&self) -> i32 {
        self.left + self.width
    }
    /// 0 at the top, 1 at the bottom.
    fn fraction(&self, y: f64) -> f64 {
        ((y - self.top as f64) / (self.height.max(2) - 1) as f64).clamp(0.0, 1.0)
    }
    fn height_at(&self, f: f64) -> f64 {
        self.top as f64 + f.clamp(0.0, 1.0) * (self.height.max(2) - 1) as f64
    }
}

/// The height (0…1) where the pointer reached the edge facing the Mac, or None.
pub fn crossing(s: &Screen, mac: Side, x: i32, y: i32) -> Option<f64> {
    let at_edge = match mac {
        Side::Left => x <= s.left,
        Side::Right => x >= s.right() - 1,
    };
    at_edge.then(|| s.fraction(y as f64))
}

/// Where the Mac's pointer comes in: just inside the edge facing the Mac, at the height it left the Mac.
pub fn entry(s: &Screen, mac: Side, f: f64) -> (f64, f64) {
    let x = match mac {
        Side::Left => s.left as f64 + 2.0,
        Side::Right => (s.right() - 3) as f64,
    };
    (x, s.height_at(f))
}

#[derive(Debug, PartialEq)]
pub enum Step {
    /// The pointer goes here.
    To(f64, f64),
    /// It was pushed off the edge facing the Mac, at this height: the Mac takes over.
    Leave(f64),
}

/// One move of the Mac's mouse while it drives this PC.
pub fn guest_step(s: &Screen, mac: Side, pos: (f64, f64), dx: f64, dy: f64) -> Step {
    let (x, y) = (pos.0 + dx, pos.1 + dy);
    let off = match mac {
        Side::Left => dx < 0.0 && x < s.left as f64,
        Side::Right => dx > 0.0 && x > (s.right() - 1) as f64,
    };
    if off {
        return Step::Leave(s.fraction(pos.1));
    }
    let x = x.clamp(s.left as f64, (s.right() - 1) as f64);
    let y = y.clamp(s.top as f64, (s.top + s.height - 1) as f64);
    Step::To(x, y)
}

const LETTERS: [&str; 26] = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z"];
const DIGITS: [&str; 10] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"];
const FKEYS: [&str; 12] = ["f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12"];

/// A Windows virtual key as the Mac names it (its modifiers as the Mac's habits), or None for keys not carried.
pub fn key_name(vk: u32) -> Option<&'static str> {
    Some(match vk {
        0x41..=0x5A => LETTERS[(vk - 0x41) as usize],
        0x30..=0x39 => DIGITS[(vk - 0x30) as usize],
        0x60..=0x69 => DIGITS[(vk - 0x60) as usize],
        0x70..=0x7B => FKEYS[(vk - 0x70) as usize],
        0x0D => "enter",
        0x09 => "tab",
        0x20 => "space",
        0x08 => "backspace",
        0x1B => "esc",
        0x2E => "delete",
        0x25 => "left",
        0x26 => "up",
        0x27 => "right",
        0x28 => "down",
        0x24 => "home",
        0x23 => "end",
        0x21 => "pageup",
        0x22 => "pagedown",
        0xBD | 0x6D => "-",
        0xBB | 0x6B => "=",
        0xDB => "[",
        0xDD => "]",
        0xDC => "\\",
        0xBA => ";",
        0xDE => "'",
        0xBC => ",",
        0xBE | 0x6E => ".",
        0xBF | 0x6F => "/",
        0xC0 => "`",
        0x11 | 0xA2 | 0xA3 => "cmd",
        0x5B | 0x5C => "ctrl",
        0x12 | 0xA4 | 0xA5 => "alt",
        0x10 | 0xA0 | 0xA1 => "shift",
        _ => return None,
    })
}

// ── State ──────────────────────────────────────────────────────────────────────────────────────────────────────────

const LOCAL: u8 = 0;
const AWAY: u8 = 1;
const GUEST: u8 = 2;

static MODE: AtomicU8 = AtomicU8::new(LOCAL);
/// When the Mac was last heard from, and when the mouse last switched sides (ms since start).
static HEARD: AtomicU64 = AtomicU64::new(0);
static SWITCHED: AtomicU64 = AtomicU64::new(0);
/// Where this PC's pointer waits while it drives the Mac (x << 32 | y).
static PARK: AtomicI64 = AtomicI64::new(0);
static NEXT: AtomicU64 = AtomicU64::new(1);

struct Peer {
    id: u64,
    tx: mpsc::Sender<Out>,
    side: Option<Side>,
}

static PEER: Mutex<Option<Peer>> = Mutex::new(None);

/// The Mac's pointer on this PC while it drives it.
#[derive(Default)]
struct Guest {
    pos: (f64, f64),
    wheel: (f64, f64),
}

static GUEST_STATE: Mutex<Guest> = Mutex::new(Guest { pos: (0.0, 0.0), wheel: (0.0, 0.0) });

fn now() -> u64 {
    static START: OnceLock<Instant> = OnceLock::new();
    START.get_or_init(Instant::now).elapsed().as_millis() as u64 + 1
}

fn side() -> Option<Side> {
    PEER.lock().unwrap().as_ref().and_then(|p| p.side)
}

/// A line to the Mac (dropped if the connection is full: the next one says where things are).
fn say(v: Value) -> bool {
    match PEER.lock().unwrap().as_ref() {
        Some(p) => p.tx.try_send(Out::Line(v.to_string().into())).is_ok(),
        None => false,
    }
}

/// This PC's phone link, so a phone can hand its address to the Mac (`shareOffer`).
type Server = (u16, String, Arc<super::server::Shared>);
static SERVER: Mutex<Option<Server>> = Mutex::new(None);

pub fn set_server(server: Option<Server>) {
    *SERVER.lock().unwrap() = server;
}

/// The link the Mac connects with (this PC's pairing link for phones on its Wi-Fi), or why there is none.
pub fn offer() -> Result<String, &'static str> {
    if !supported() {
        return Err("Sharing one mouse works with Windows PCs for now.");
    }
    let guard = SERVER.lock().unwrap();
    let (port, fp, shared) = guard.as_ref().ok_or("Turn on the phone link on the PC first (Nyeko → Phone).")?;
    let host = super::pairing::lan_address().ok_or("The PC is not on a local network.")?.to_string();
    let token = shared.token.lock().unwrap().clone();
    Ok(super::pairing::pairing_link(&host, *port, fp, &token, &shared.name))
}

/// A Mac connected and asked for `share`. One at a time: the newest wins.
pub fn connect(tx: mpsc::Sender<Out>) -> u64 {
    let id = NEXT.fetch_add(1, Ordering::SeqCst);
    let old = PEER.lock().unwrap().replace(Peer { id, tx, side: None });
    if old.is_some() {
        home();
    }
    HEARD.store(now(), Ordering::SeqCst);
    worker();
    id
}

pub fn disconnect(id: u64) {
    let mut peer = PEER.lock().unwrap();
    if peer.as_ref().is_some_and(|p| p.id == id) {
        *peer = None;
        drop(peer);
        home();
        os::hook_stop();
    }
}

pub fn heard(id: u64) {
    if PEER.lock().unwrap().as_ref().is_some_and(|p| p.id == id) {
        HEARD.store(now(), Ordering::SeqCst);
    }
}

/// The mouse and keyboard are this PC's again (the link ended or went silent).
fn home() {
    match MODE.swap(LOCAL, Ordering::SeqCst) {
        GUEST => os::release(),
        AWAY => {
            let (x, y) = park();
            os::set_cursor(x, y);
        }
        _ => {}
    }
    SWITCHED.store(now(), Ordering::SeqCst);
}

fn park() -> (i32, i32) {
    let v = PARK.load(Ordering::SeqCst);
    ((v >> 32) as i32, v as i32)
}

pub fn handle(id: u64, msg: &Value) {
    if !PEER.lock().unwrap().as_ref().is_some_and(|p| p.id == id) {
        return;
    }
    match msg["type"].as_str().unwrap_or("") {
        "share" => {
            let s = Side::of_mac(msg["side"].as_str().unwrap_or(""));
            if let Some(p) = PEER.lock().unwrap().as_mut() {
                p.side = s;
            }
            if s.is_some() && supported() {
                os::hook_start();
            } else {
                home();
                os::hook_stop();
            }
            let note = if supported() { "" } else { "Sharing one mouse works with Windows PCs for now." };
            say(json!({ "type": "shareState", "ok": supported(), "note": note }));
        }
        "shareEnter" => {
            let Some(mac) = side() else { return };
            let f = msg["y"].as_f64().filter(|f| f.is_finite()).unwrap_or(0.5);
            let s = os::screen();
            let (x, y) = entry(&s, mac, f);
            MODE.store(GUEST, Ordering::SeqCst);
            SWITCHED.store(now(), Ordering::SeqCst);
            *GUEST_STATE.lock().unwrap() = Guest { pos: (x, y), wheel: (0.0, 0.0) };
            os::move_to(&s, x, y);
        }
        "shareLeave" => {
            let Some(mac) = side() else { return };
            if MODE.compare_exchange(AWAY, LOCAL, Ordering::SeqCst, Ordering::SeqCst).is_ok() {
                SWITCHED.store(now(), Ordering::SeqCst);
                let s = os::screen();
                let f = msg["y"].as_f64().filter(|f| f.is_finite()).unwrap_or(0.5);
                // Just inside the edge, so the pointer does not go straight back.
                let x = match mac {
                    Side::Left => s.left + 4,
                    Side::Right => s.right() - 5,
                };
                os::set_cursor(x, s.height_at(f) as i32);
            }
        }
        "input" if MODE.load(Ordering::SeqCst) == GUEST => {
            let Some(mac) = side() else { return };
            let events = msg["e"].as_array().cloned().unwrap_or_default();
            guest_input(mac, &events);
        }
        _ => {}
    }
}

fn num(v: &Value, limit: f64) -> f64 {
    let d = v.as_f64().unwrap_or(0.0);
    if d.is_finite() { d.clamp(-limit, limit) } else { 0.0 }
}

fn guest_input(mac: Side, events: &[Value]) {
    let s = os::screen();
    for e in events.iter().take(400) {
        let name = |k: &str| e[k].as_str().filter(|n| n.len() <= 12).unwrap_or("").to_lowercase();
        match e["k"].as_str().unwrap_or("") {
            "move" => {
                let pos = GUEST_STATE.lock().unwrap().pos;
                match guest_step(&s, mac, pos, num(&e["dx"], 4000.0), num(&e["dy"], 4000.0)) {
                    Step::To(x, y) => {
                        GUEST_STATE.lock().unwrap().pos = (x, y);
                        os::move_to(&s, x, y);
                    }
                    Step::Leave(f) => {
                        if MODE.compare_exchange(GUEST, LOCAL, Ordering::SeqCst, Ordering::SeqCst).is_ok() {
                            SWITCHED.store(now(), Ordering::SeqCst);
                            os::release();
                            say(json!({ "type": "shareLeave", "y": f }));
                            let x = match mac {
                                Side::Left => s.left + 4,
                                Side::Right => s.right() - 5,
                            };
                            os::set_cursor(x, pos.1 as i32);
                        }
                        return;
                    }
                }
            }
            "down" | "up" => os::button(e["b"].as_str().unwrap_or("left"), e["k"] == "down"),
            "kd" | "ku" => os::key(&name("key"), e["k"] == "kd"),
            "scroll" => {
                // A wheel notch is 120; about 40 of the Mac's pixels make one. dy > 0 shows what is further down.
                let mut g = GUEST_STATE.lock().unwrap();
                g.wheel.0 += num(&e["dx"], 4000.0) * 3.0;
                g.wheel.1 += num(&e["dy"], 4000.0) * 3.0;
                let (x, y) = (g.wheel.0.trunc(), g.wheel.1.trunc());
                g.wheel.0 -= x;
                g.wheel.1 -= y;
                drop(g);
                os::wheel(x as i32, -(y as i32));
            }
            "release" => os::release(),
            _ => {}
        }
    }
}

// ── Away: this PC's mouse and keyboard drive the Mac ───────────────────────────────────────────────────────────────

/// What the hooks caught, on its way to the Mac.
#[derive(Debug)]
pub enum Caught {
    Move(i32, i32),
    Button(&'static str, bool),
    Scroll(f64, f64),
    Key(&'static str, bool),
}

static CAUGHT: OnceLock<Mutex<std::sync::mpsc::Sender<Caught>>> = OnceLock::new();
static WORKER: AtomicBool = AtomicBool::new(false);

fn catch(c: Caught) {
    if let Some(tx) = CAUGHT.get() {
        let _ = tx.lock().unwrap().send(c);
    }
}

/// The pointer reached the edge facing the Mac (from the mouse hook): the Mac gets the mouse and keyboard.
fn go_away(f: f64) {
    if MODE.compare_exchange(LOCAL, AWAY, Ordering::SeqCst, Ordering::SeqCst).is_err() {
        return;
    }
    SWITCHED.store(now(), Ordering::SeqCst);
    say(json!({ "type": "shareEnter", "y": f }));
    let (x, y) = os::park_point();
    PARK.store(((x as i64) << 32) | (y as u32 as i64), Ordering::SeqCst);
    os::set_cursor(x, y);
}

/// The hooks' decisions (they run on the hook thread and must answer quickly). True: the event is swallowed.
pub fn mouse_event(kind: MouseKind, x: i32, y: i32, wheel: i16) -> bool {
    static BUTTONS: AtomicU8 = AtomicU8::new(0);
    match MODE.load(Ordering::SeqCst) {
        LOCAL => {
            match kind {
                MouseKind::Down(_) => {
                    BUTTONS.fetch_add(1, Ordering::SeqCst);
                }
                MouseKind::Up(_) => {
                    let _ = BUTTONS.fetch_update(Ordering::SeqCst, Ordering::SeqCst, |b| Some(b.saturating_sub(1)));
                }
                MouseKind::Move => {
                    // Not while a button is held (a window being dragged stays on this PC), nor right after a switch.
                    if BUTTONS.load(Ordering::SeqCst) == 0 && now().saturating_sub(SWITCHED.load(Ordering::SeqCst)) > 300 {
                        if let Some(f) = side().and_then(|mac| crossing(&os::screen(), mac, x, y)) {
                            go_away(f);
                            return true;
                        }
                    }
                }
                _ => {}
            }
            false
        }
        AWAY => {
            let (px, py) = park();
            match kind {
                MouseKind::Move => {
                    let (dx, dy) = (x - px, y - py);
                    if dx != 0 || dy != 0 {
                        catch(Caught::Move(dx, dy));
                    }
                }
                MouseKind::Down(b) => catch(Caught::Button(b, true)),
                MouseKind::Up(b) => catch(Caught::Button(b, false)),
                MouseKind::Wheel => catch(Caught::Scroll(0.0, -(wheel as f64) / 3.0)),
                MouseKind::HWheel => catch(Caught::Scroll(wheel as f64 / 3.0, 0.0)),
            }
            true
        }
        _ => {
            // The Mac drives this PC and someone touched the PC's own mouse: the PC takes itself back.
            if matches!(kind, MouseKind::Move | MouseKind::Down(_)) && now().saturating_sub(SWITCHED.load(Ordering::SeqCst)) > 300 {
                if MODE.compare_exchange(GUEST, LOCAL, Ordering::SeqCst, Ordering::SeqCst).is_ok() {
                    SWITCHED.store(now(), Ordering::SeqCst);
                    os::release();
                    say(json!({ "type": "shareLeave", "y": os::screen().fraction(y as f64) }));
                }
            }
            false
        }
    }
}

pub fn key_event(vk: u32, down: bool) -> bool {
    if MODE.load(Ordering::SeqCst) != AWAY {
        return false;
    }
    if let Some(name) = key_name(vk) {
        catch(Caught::Key(name, down));
    }
    true
}

#[derive(Clone, Copy, Debug)]
pub enum MouseKind {
    Move,
    Down(&'static str),
    Up(&'static str),
    Wheel,
    HWheel,
}

/// One caught event into the batch: moves are added up until something else comes, which keeps the order.
fn add(c: Caught, batch: &mut Vec<Value>, moved: &mut (i32, i32)) {
    let line = match c {
        Caught::Move(dx, dy) => {
            moved.0 += dx;
            moved.1 += dy;
            return;
        }
        Caught::Button(b, down) => json!({ "k": if down { "down" } else { "up" }, "b": b }),
        Caught::Scroll(dx, dy) => json!({ "k": "scroll", "dx": dx, "dy": dy }),
        Caught::Key(k, down) => json!({ "k": if down { "kd" } else { "ku" }, "key": k }),
    };
    if *moved != (0, 0) {
        batch.push(json!({ "k": "move", "dx": moved.0, "dy": moved.1 }));
        *moved = (0, 0);
    }
    batch.push(line);
}

/// Sends what the hooks caught to the Mac, about every 8 ms (moves added up), and pings it every 2 s.
fn worker() {
    if WORKER.swap(true, Ordering::SeqCst) {
        return;
    }
    let (tx, rx) = std::sync::mpsc::channel::<Caught>();
    let _ = CAUGHT.set(Mutex::new(tx));
    let _ = std::thread::Builder::new().name("nyeko-share".into()).spawn(move || {
        let mut batch: Vec<Value> = Vec::new();
        let mut moved = (0i32, 0i32);
        let mut flushed = Instant::now();
        let mut pinged = Instant::now();
        loop {
            let away = MODE.load(Ordering::SeqCst) == AWAY;
            // Idle (nothing to send) it wakes only for the heartbeat.
            let wait = if away || !batch.is_empty() || moved != (0, 0) {
                Duration::from_millis(8).saturating_sub(flushed.elapsed()).max(Duration::from_millis(1))
            } else {
                Duration::from_secs(2)
            };
            match rx.recv_timeout(wait) {
                Ok(c) => add(c, &mut batch, &mut moved),
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => return,
            }
            while let Ok(c) = rx.try_recv() {
                add(c, &mut batch, &mut moved);
            }
            if flushed.elapsed() >= Duration::from_millis(8) {
                if moved != (0, 0) {
                    batch.push(json!({ "k": "move", "dx": moved.0, "dy": moved.1 }));
                    moved = (0, 0);
                }
                if !batch.is_empty() && MODE.load(Ordering::SeqCst) == AWAY {
                    say(json!({ "type": "input", "raw": true, "e": batch }));
                }
                batch.clear();
                flushed = Instant::now();
            }
            if pinged.elapsed() >= Duration::from_secs(2) {
                pinged = Instant::now();
                if side().is_some() {
                    say(json!({ "type": "ping" }));
                }
                if MODE.load(Ordering::SeqCst) != LOCAL && now().saturating_sub(HEARD.load(Ordering::SeqCst)) > 7000 {
                    home();
                }
            }
        }
    });
}

// ── Windows ────────────────────────────────────────────────────────────────────────────────────────────────────────

#[cfg(windows)]
mod os {
    use super::super::remote_input::os as ri;
    use super::{MouseKind, Screen};
    use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
    use std::sync::Mutex;
    use windows::Win32::Foundation::{HINSTANCE, LPARAM, LRESULT, WPARAM};
    use windows::Win32::System::LibraryLoader::GetModuleHandleW;
    use windows::Win32::System::Threading::GetCurrentThreadId;
    use windows::Win32::UI::Input::KeyboardAndMouse::{
        KEYBD_EVENT_FLAGS, KEYEVENTF_EXTENDEDKEY, KEYEVENTF_KEYUP, MOUSEEVENTF_ABSOLUTE, MOUSEEVENTF_HWHEEL, MOUSEEVENTF_LEFTDOWN,
        MOUSEEVENTF_LEFTUP, MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP, MOUSEEVENTF_MOVE, MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP,
        MOUSEEVENTF_VIRTUALDESK, MOUSEEVENTF_WHEEL,
    };
    use windows::Win32::UI::WindowsAndMessaging::{
        CallNextHookEx, GetMessageW, GetSystemMetrics, PostThreadMessageW, SetCursorPos, SetWindowsHookExW, UnhookWindowsHookEx,
        KBDLLHOOKSTRUCT, LLKHF_INJECTED, LLMHF_INJECTED, MSG, MSLLHOOKSTRUCT, SM_CXSCREEN, SM_CXVIRTUALSCREEN, SM_CYSCREEN,
        SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN, WH_KEYBOARD_LL, WH_MOUSE_LL, WM_KEYDOWN, WM_KEYUP, WM_LBUTTONDOWN,
        WM_LBUTTONUP, WM_MBUTTONDOWN, WM_MBUTTONUP, WM_MOUSEHWHEEL, WM_MOUSEMOVE, WM_MOUSEWHEEL, WM_QUIT, WM_RBUTTONDOWN, WM_RBUTTONUP,
        WM_SYSKEYDOWN, WM_SYSKEYUP,
    };

    pub fn screen() -> Screen {
        unsafe {
            Screen {
                left: GetSystemMetrics(SM_XVIRTUALSCREEN),
                top: GetSystemMetrics(SM_YVIRTUALSCREEN),
                width: GetSystemMetrics(SM_CXVIRTUALSCREEN).max(1),
                height: GetSystemMetrics(SM_CYVIRTUALSCREEN).max(1),
            }
        }
    }

    /// The middle of the main screen: the pointer waits there while it drives the Mac, so it can move every way.
    pub fn park_point() -> (i32, i32) {
        unsafe { (GetSystemMetrics(SM_CXSCREEN) / 2, GetSystemMetrics(SM_CYSCREEN) / 2) }
    }

    pub fn set_cursor(x: i32, y: i32) {
        unsafe {
            let _ = SetCursorPos(x, y);
        }
    }

    pub fn move_to(s: &Screen, x: f64, y: f64) {
        let nx = ((x - s.left as f64) * 65535.0 / (s.width - 1).max(1) as f64).round() as i32;
        let ny = ((y - s.top as f64) * 65535.0 / (s.height - 1).max(1) as f64).round() as i32;
        ri::send(&[ri::mouse(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK, nx, ny, 0)]);
    }

    /// Buttons and keys the Mac holds down here, let go when it leaves.
    static HELD_BUTTONS: Mutex<Vec<&'static str>> = Mutex::new(Vec::new());
    static HELD_KEYS: Mutex<Vec<(u16, bool)>> = Mutex::new(Vec::new());

    pub fn button(b: &str, down: bool) {
        let (b, flag): (&'static str, _) = match (b, down) {
            ("right", true) => ("right", MOUSEEVENTF_RIGHTDOWN),
            ("right", false) => ("right", MOUSEEVENTF_RIGHTUP),
            ("middle", true) => ("middle", MOUSEEVENTF_MIDDLEDOWN),
            ("middle", false) => ("middle", MOUSEEVENTF_MIDDLEUP),
            (_, true) => ("left", MOUSEEVENTF_LEFTDOWN),
            (_, false) => ("left", MOUSEEVENTF_LEFTUP),
        };
        let mut held = HELD_BUTTONS.lock().unwrap();
        held.retain(|h| *h != b);
        if down {
            held.push(b);
        }
        ri::send(&[ri::mouse(flag, 0, 0, 0)]);
    }

    pub fn wheel(x: i32, y: i32) {
        if y != 0 {
            ri::send(&[ri::mouse(MOUSEEVENTF_WHEEL, 0, 0, y)]);
        }
        if x != 0 {
            ri::send(&[ri::mouse(MOUSEEVENTF_HWHEEL, 0, 0, x)]);
        }
    }

    /// A key by name (the Mac's ⌘ and ⌃ arrive as "ctrl").
    pub fn key(name: &str, down: bool) {
        let Some((vk, extended)) = ri::modifier(name).map(|m| (m, m == 0x5B)).or_else(|| ri::vk(name)) else { return };
        let mut flags = if extended { KEYEVENTF_EXTENDEDKEY } else { KEYBD_EVENT_FLAGS(0) };
        if !down {
            flags |= KEYEVENTF_KEYUP;
        }
        let mut held = HELD_KEYS.lock().unwrap();
        held.retain(|(k, _)| *k != vk);
        if down {
            held.push((vk, extended));
        }
        ri::send(&[ri::key(vk, 0, flags)]);
    }

    pub fn release() {
        for b in std::mem::take(&mut *HELD_BUTTONS.lock().unwrap()) {
            let flag = match b {
                "right" => MOUSEEVENTF_RIGHTUP,
                "middle" => MOUSEEVENTF_MIDDLEUP,
                _ => MOUSEEVENTF_LEFTUP,
            };
            ri::send(&[ri::mouse(flag, 0, 0, 0)]);
        }
        for (vk, extended) in std::mem::take(&mut *HELD_KEYS.lock().unwrap()) {
            let ext = if extended { KEYEVENTF_EXTENDEDKEY } else { KEYBD_EVENT_FLAGS(0) };
            ri::send(&[ri::key(vk, 0, ext | KEYEVENTF_KEYUP)]);
        }
    }

    // The low-level hooks: on their own thread with a message loop, only while a Mac shares this PC's mouse.

    static RUNNING: AtomicBool = AtomicBool::new(false);
    static WANTED: AtomicBool = AtomicBool::new(false);
    static THREAD: AtomicU32 = AtomicU32::new(0);

    unsafe extern "system" fn mouse_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
        if code >= 0 {
            let info = &*(lparam.0 as *const MSLLHOOKSTRUCT);
            // Events Nyeko posts itself (the Mac driving this PC) are never caught again.
            if info.flags & LLMHF_INJECTED == 0 {
                let kind = match wparam.0 as u32 {
                    WM_MOUSEMOVE => Some(MouseKind::Move),
                    WM_LBUTTONDOWN => Some(MouseKind::Down("left")),
                    WM_LBUTTONUP => Some(MouseKind::Up("left")),
                    WM_RBUTTONDOWN => Some(MouseKind::Down("right")),
                    WM_RBUTTONUP => Some(MouseKind::Up("right")),
                    WM_MBUTTONDOWN => Some(MouseKind::Down("middle")),
                    WM_MBUTTONUP => Some(MouseKind::Up("middle")),
                    WM_MOUSEWHEEL => Some(MouseKind::Wheel),
                    WM_MOUSEHWHEEL => Some(MouseKind::HWheel),
                    _ => None,
                };
                if let Some(kind) = kind {
                    let wheel = (info.mouseData >> 16) as u16 as i16;
                    if super::mouse_event(kind, info.pt.x, info.pt.y, wheel) {
                        return LRESULT(1);
                    }
                }
            }
        }
        CallNextHookEx(None, code, wparam, lparam)
    }

    unsafe extern "system" fn key_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
        if code >= 0 {
            let info = &*(lparam.0 as *const KBDLLHOOKSTRUCT);
            if !info.flags.contains(LLKHF_INJECTED) {
                let down = match wparam.0 as u32 {
                    WM_KEYDOWN | WM_SYSKEYDOWN => Some(true),
                    WM_KEYUP | WM_SYSKEYUP => Some(false),
                    _ => None,
                };
                if let Some(down) = down {
                    if super::key_event(info.vkCode, down) {
                        return LRESULT(1);
                    }
                }
            }
        }
        CallNextHookEx(None, code, wparam, lparam)
    }

    pub fn hook_start() {
        WANTED.store(true, Ordering::SeqCst);
        if RUNNING.swap(true, Ordering::SeqCst) {
            return;
        }
        let _ = std::thread::Builder::new().name("nyeko-share-hooks".into()).spawn(|| unsafe {
            THREAD.store(GetCurrentThreadId(), Ordering::SeqCst);
            let module = GetModuleHandleW(windows::core::PCWSTR::null()).ok().map(|m| HINSTANCE(m.0));
            let mouse = SetWindowsHookExW(WH_MOUSE_LL, Some(mouse_proc), module, 0);
            let keys = SetWindowsHookExW(WH_KEYBOARD_LL, Some(key_proc), module, 0);
            if mouse.is_err() || keys.is_err() {
                crate::log::line("shared mouse: the PC did not let Nyeko watch its mouse and keyboard");
            }
            let mut msg = MSG::default();
            while WANTED.load(Ordering::SeqCst) && GetMessageW(&mut msg, None, 0, 0).0 > 0 {}
            if let Ok(h) = mouse {
                let _ = UnhookWindowsHookEx(h);
            }
            if let Ok(h) = keys {
                let _ = UnhookWindowsHookEx(h);
            }
            THREAD.store(0, Ordering::SeqCst);
            RUNNING.store(false, Ordering::SeqCst);
            // Asked for again while it was stopping.
            if WANTED.load(Ordering::SeqCst) {
                hook_start();
            }
        });
    }

    pub fn hook_stop() {
        WANTED.store(false, Ordering::SeqCst);
        let t = THREAD.load(Ordering::SeqCst);
        if t != 0 {
            unsafe {
                let _ = PostThreadMessageW(t, WM_QUIT, WPARAM(0), LPARAM(0));
            }
        }
    }
}

#[cfg(not(windows))]
mod os {
    use super::Screen;
    pub fn screen() -> Screen {
        Screen { left: 0, top: 0, width: 1920, height: 1080 }
    }
    pub fn park_point() -> (i32, i32) {
        (960, 540)
    }
    pub fn set_cursor(_: i32, _: i32) {}
    pub fn move_to(_: &Screen, _: f64, _: f64) {}
    pub fn button(_: &str, _: bool) {}
    pub fn wheel(_: i32, _: i32) {}
    pub fn key(_: &str, _: bool) {}
    pub fn release() {}
    pub fn hook_start() {}
    pub fn hook_stop() {}
}

#[cfg(test)]
mod tests {
    use super::*;

    const S: Screen = Screen { left: 0, top: 0, width: 1920, height: 1080 };

    #[test]
    fn the_mac_side_is_the_other_way_round() {
        assert_eq!(Side::of_mac("left"), Some(Side::Right));
        assert_eq!(Side::of_mac("right"), Some(Side::Left));
        assert_eq!(Side::of_mac("off"), None);
    }

    #[test]
    fn the_pointer_crosses_only_at_the_edge_facing_the_mac() {
        assert_eq!(crossing(&S, Side::Right, 1919, 0), Some(0.0));
        assert_eq!(crossing(&S, Side::Right, 1925, 1079), Some(1.0));
        assert_eq!(crossing(&S, Side::Right, 0, 500), None);
        assert_eq!(crossing(&S, Side::Left, 0, 1079), Some(1.0));
        assert_eq!(crossing(&S, Side::Left, 1919, 10), None);
    }

    #[test]
    fn the_mac_pointer_comes_in_and_leaves_by_the_same_edge() {
        let (x, y) = entry(&S, Side::Right, 0.5);
        assert_eq!((x, y.round()), (1917.0, 540.0));
        // Moving away from the Mac stays on the PC; pushing past its edge hands back.
        assert_eq!(guest_step(&S, Side::Right, (x, y), -100.0, 0.0), Step::To(1817.0, y));
        assert!(matches!(guest_step(&S, Side::Right, (1919.0, 0.0), 5.0, 0.0), Step::Leave(f) if f == 0.0));
        // The other edges hold the pointer.
        assert_eq!(guest_step(&S, Side::Right, (10.0, 10.0), -50.0, -50.0), Step::To(0.0, 0.0));
        assert!(matches!(guest_step(&S, Side::Left, (1.0, 1079.0), -5.0, 0.0), Step::Leave(f) if f == 1.0));
    }

    #[test]
    fn keys_go_by_name_with_the_macs_modifiers() {
        assert_eq!(key_name(0x41), Some("a"));
        assert_eq!(key_name(0x5A), Some("z"));
        assert_eq!(key_name(0x39), Some("9"));
        assert_eq!(key_name(0x7B), Some("f12"));
        assert_eq!(key_name(0xA2), Some("cmd"));
        assert_eq!(key_name(0x5B), Some("ctrl"));
        assert_eq!(key_name(0xA4), Some("alt"));
        assert_eq!(key_name(0x2E), Some("delete"));
        assert_eq!(key_name(0xFF), None);
    }
}
