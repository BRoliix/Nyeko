//! Nyeko: the phone as this computer's trackpad and keyboard (docs/REMOTE_INPUT.md). The phone sends small batches
//! ({type:"input", e:[…]}), about 25 a second (the relay's own limit is 30); each is posted with SendInput, a move
//! spread over a few steps 8 ms apart so the pointer glides. The phone asks for Face ID before it opens the trackpad.
//! Same events as the Mac (MacRemoteInput.swift). Linux: not yet (the phone says so).

use std::time::Duration;

use serde_json::Value;

#[derive(Clone, Debug, PartialEq)]
pub enum Event {
    Move(f64, f64),
    Down(bool),
    Up(bool),
    Click(bool, u8),
    Scroll(f64, f64),
    Text(String),
    Key(String, Vec<String>),
    Release,
}

fn num(v: &Value, limit: f64) -> f64 {
    let d = v.as_f64().unwrap_or(0.0);
    if d.is_finite() { d.clamp(-limit, limit) } else { 0.0 }
}

/// One event from the phone, checked (None for anything unknown or malformed).
pub fn parse(e: &Value) -> Option<Event> {
    let right = e["b"].as_str() == Some("right");
    Some(match e["k"].as_str()? {
        "move" => Event::Move(num(&e["dx"], 4000.0), num(&e["dy"], 4000.0)),
        "down" => Event::Down(right),
        "up" => Event::Up(right),
        "click" => Event::Click(right, num(&e["n"], 3.0).max(1.0) as u8),
        "scroll" => Event::Scroll(num(&e["dx"], 4000.0), num(&e["dy"], 4000.0)),
        "text" => Event::Text(e["t"].as_str()?.chars().take(500).collect()),
        "key" => Event::Key(
            e["key"].as_str()?.chars().take(12).collect(),
            e["mods"].as_array().map(|m| m.iter().filter_map(|x| x.as_str()).filter(|x| x.len() < 8).map(String::from).collect()).unwrap_or_default(),
        ),
        "release" => Event::Release,
        _ => return None,
    })
}

/// A batch as steps: (wait before, event). A move becomes up to four smaller moves 8 ms apart.
pub fn plan(events: &[Value]) -> Vec<(Duration, Event)> {
    let mut out = Vec::new();
    for e in events.iter().take(200) {
        let Some(ev) = parse(e) else { continue };
        if let Event::Move(dx, dy) = ev {
            let steps = ((dx.hypot(dy) / 6.0) as usize).clamp(1, 4);
            for i in 0..steps {
                let wait = if i == 0 { Duration::ZERO } else { Duration::from_millis(8) };
                out.push((wait, Event::Move(dx / steps as f64, dy / steps as f64)));
            }
        } else {
            out.push((Duration::ZERO, ev));
        }
    }
    out
}

/// Whether this computer can take the phone's input.
pub fn supported() -> bool {
    cfg!(windows)
}

/// Runs a batch on the input thread (batches run in order, one after another).
pub fn handle(events: &[Value]) {
    let steps = plan(events);
    if steps.is_empty() || !supported() {
        return;
    }
    use std::sync::{mpsc, Mutex, OnceLock};
    static WORKER: OnceLock<Mutex<mpsc::Sender<Vec<(Duration, Event)>>>> = OnceLock::new();
    let tx = WORKER.get_or_init(|| {
        let (tx, rx) = mpsc::channel::<Vec<(Duration, Event)>>();
        std::thread::Builder::new()
            .name("nyeko-remote-input".into())
            .spawn(move || {
                let mut state = os::State::default();
                for batch in rx {
                    for (wait, ev) in batch {
                        if !wait.is_zero() {
                            std::thread::sleep(wait);
                        }
                        os::apply(&mut state, &ev);
                    }
                }
            })
            .expect("input thread");
        Mutex::new(tx)
    });
    let _ = tx.lock().unwrap().send(steps);
}

#[cfg(windows)]
mod os {
    use super::Event;
    use windows::Win32::UI::Input::KeyboardAndMouse::{
        SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, INPUT_MOUSE, KEYBDINPUT, KEYBD_EVENT_FLAGS, KEYEVENTF_EXTENDEDKEY, KEYEVENTF_KEYUP,
        KEYEVENTF_UNICODE, MOUSEEVENTF_HWHEEL, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP, MOUSEEVENTF_MOVE, MOUSEEVENTF_RIGHTDOWN,
        MOUSEEVENTF_RIGHTUP, MOUSEEVENTF_WHEEL, MOUSEINPUT, MOUSE_EVENT_FLAGS, VIRTUAL_KEY,
    };

    #[derive(Default)]
    pub struct State {
        left: bool,
        right: bool,
        carry: (f64, f64),
        wheel: (f64, f64),
    }

    fn mouse(flags: MOUSE_EVENT_FLAGS, dx: i32, dy: i32, data: i32) -> INPUT {
        INPUT { r#type: INPUT_MOUSE, Anonymous: INPUT_0 { mi: MOUSEINPUT { dx, dy, mouseData: data as u32, dwFlags: flags, time: 0, dwExtraInfo: 0 } } }
    }

    fn key(vk: u16, scan: u16, flags: KEYBD_EVENT_FLAGS) -> INPUT {
        INPUT { r#type: INPUT_KEYBOARD, Anonymous: INPUT_0 { ki: KEYBDINPUT { wVk: VIRTUAL_KEY(vk), wScan: scan, dwFlags: flags, time: 0, dwExtraInfo: 0 } } }
    }

    fn send(inputs: &[INPUT]) {
        unsafe {
            SendInput(inputs, std::mem::size_of::<INPUT>() as i32);
        }
    }

    /// Windows virtual keys for the keys the phone names, and whether each is an "extended" key.
    fn vk(name: &str) -> Option<(u16, bool)> {
        Some(match name {
            "enter" => (0x0D, false), "tab" => (0x09, false), "space" => (0x20, false), "backspace" => (0x08, false), "esc" => (0x1B, false),
            "delete" => (0x2E, true), "left" => (0x25, true), "up" => (0x26, true), "right" => (0x27, true), "down" => (0x28, true),
            "home" => (0x24, true), "end" => (0x23, true), "pageup" => (0x21, true), "pagedown" => (0x22, true),
            "-" => (0xBD, false), "=" => (0xBB, false), "[" => (0xDB, false), "]" => (0xDD, false), "\\" => (0xDC, false),
            ";" => (0xBA, false), "'" => (0xDE, false), "," => (0xBC, false), "." => (0xBE, false), "/" => (0xBF, false), "`" => (0xC0, false),
            n if n.len() == 1 && n.as_bytes()[0].is_ascii_alphanumeric() => (n.to_ascii_uppercase().as_bytes()[0] as u16, false),
            n if n.starts_with('f') && n[1..].parse::<u16>().is_ok_and(|f| (1..=12).contains(&f)) => (0x6F + n[1..].parse::<u16>().unwrap(), false),
            _ => return None,
        })
    }

    fn modifier(name: &str) -> Option<u16> {
        Some(match name {
            "ctrl" => 0x11, "shift" => 0x10, "alt" | "option" => 0x12, "cmd" | "meta" | "win" => 0x5B,
            _ => return None,
        })
    }

    pub fn apply(s: &mut State, ev: &Event) {
        match ev {
            Event::Move(dx, dy) => {
                s.carry.0 += dx;
                s.carry.1 += dy;
                let (x, y) = (s.carry.0.trunc(), s.carry.1.trunc());
                s.carry.0 -= x;
                s.carry.1 -= y;
                if x != 0.0 || y != 0.0 {
                    send(&[mouse(MOUSEEVENTF_MOVE, x as i32, y as i32, 0)]);
                }
            }
            Event::Down(right) | Event::Up(right) => {
                let down = matches!(ev, Event::Down(_));
                let flag = match (right, down) {
                    (false, true) => MOUSEEVENTF_LEFTDOWN, (false, false) => MOUSEEVENTF_LEFTUP,
                    (true, true) => MOUSEEVENTF_RIGHTDOWN, (true, false) => MOUSEEVENTF_RIGHTUP,
                };
                if *right { s.right = down } else { s.left = down }
                send(&[mouse(flag, 0, 0, 0)]);
            }
            Event::Click(right, n) => {
                let (d, u) = if *right { (MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP) } else { (MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP) };
                let mut inputs = Vec::new();
                for _ in 0..*n {
                    inputs.push(mouse(d, 0, 0, 0));
                    inputs.push(mouse(u, 0, 0, 0));
                }
                send(&inputs);
            }
            Event::Scroll(dx, dy) => {
                // A wheel notch is 120; about 40 of the phone's pixels make one.
                s.wheel.0 += dx * 3.0;
                s.wheel.1 += dy * 3.0;
                let (x, y) = (s.wheel.0.trunc(), s.wheel.1.trunc());
                s.wheel.0 -= x;
                s.wheel.1 -= y;
                if y != 0.0 {
                    send(&[mouse(MOUSEEVENTF_WHEEL, 0, 0, -(y as i32))]);
                }
                if x != 0.0 {
                    send(&[mouse(MOUSEEVENTF_HWHEEL, 0, 0, x as i32)]);
                }
            }
            Event::Text(t) => {
                // The characters themselves (any language), not keys.
                let mut inputs = Vec::new();
                for unit in t.encode_utf16() {
                    inputs.push(key(0, unit, KEYEVENTF_UNICODE));
                    inputs.push(key(0, unit, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP));
                }
                for chunk in inputs.chunks(64) {
                    send(chunk);
                }
            }
            Event::Key(name, mods) => {
                let Some((code, extended)) = vk(&name.to_lowercase()) else { return };
                let mods: Vec<u16> = mods.iter().filter_map(|m| modifier(m)).collect();
                let ext = if extended { KEYEVENTF_EXTENDEDKEY } else { KEYBD_EVENT_FLAGS(0) };
                let mut inputs: Vec<INPUT> = mods.iter().map(|m| key(*m, 0, KEYBD_EVENT_FLAGS(0))).collect();
                inputs.push(key(code, 0, ext));
                inputs.push(key(code, 0, ext | KEYEVENTF_KEYUP));
                inputs.extend(mods.iter().rev().map(|m| key(*m, 0, KEYEVENTF_KEYUP)));
                send(&inputs);
            }
            Event::Release => {
                if s.left {
                    send(&[mouse(MOUSEEVENTF_LEFTUP, 0, 0, 0)]);
                    s.left = false;
                }
                if s.right {
                    send(&[mouse(MOUSEEVENTF_RIGHTUP, 0, 0, 0)]);
                    s.right = false;
                }
                s.carry = (0.0, 0.0);
                s.wheel = (0.0, 0.0);
            }
        }
    }
}

#[cfg(not(windows))]
mod os {
    use super::Event;
    #[derive(Default)]
    pub struct State;
    pub fn apply(_: &mut State, _: &Event) {}
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn events_are_checked_and_moves_spread_out() {
        let steps = plan(&[
            json!({ "k": "move", "dx": 24, "dy": 0 }),
            json!({ "k": "click", "b": "right", "n": 9 }),
            json!({ "k": "move", "dx": 1e9, "dy": "x" }),
            json!({ "k": "nope" }),
            json!({ "k": "key", "key": "c", "mods": ["cmd", "averyveryverylongname"] }),
        ]);
        assert_eq!(steps[0], (Duration::ZERO, Event::Move(6.0, 0.0)));
        assert_eq!(steps.iter().filter(|(_, e)| matches!(e, Event::Move(..))).count(), 4 + 4);
        assert!(steps.contains(&(Duration::ZERO, Event::Click(true, 3))));
        assert!(steps.contains(&(Duration::ZERO, Event::Move(1000.0, 0.0))));
        assert!(steps.contains(&(Duration::ZERO, Event::Key("c".into(), vec!["cmd".into()]))));
        assert_eq!(parse(&json!({ "k": "text", "t": "é".repeat(900) })), Some(Event::Text("é".repeat(500))));
    }
}
