// Nyeko (Broly's private build): the phone controls this computer and talks to its coding sessions, with the same
// `nyeko` messages as Nyeko on the Mac (NyekoPhoneService.swift, SessionChat.swift). Offered only to a phone that asks.
//
// - status: the computer's card (its name, sound, battery, what is playing, the recent project folders);
// - control: play/pause, next, previous, volume and mute, lock, screen off, sleep, restart, shut down, a screenshot,
//   open an app, bring a session's window forward;
// - open / close: a coding session's conversation, read from Claude Code's transcript while the phone shows it;
// - say / unqueue: a message to a session. Claude idle: typed into its terminal (its window comes forward, as for a
//   dropped file). Claude working or waiting: kept here and handed to Claude by the Stop hook when its turn ends
//   (coucou-hook's stop_check);
// - launch: a new Claude Code session in one of the recent folders (launch.rs);
// - listApps: the apps of the Start menu (Windows) or of the desktop files (Linux), to open one;
// - ask: Nyo's chat, a few words it understands as commands.
// The log says what happened ("nyeko: lock"), never what was said, typed or read.

use std::collections::HashMap;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::Duration;

use serde_json::{json, Value};
use tokio::sync::mpsc;

use super::hub::Out;

/// How a message from the phone is put to Claude (the Stop hook's reason); recognised again in the transcript.
pub const PHONE_PREFIX: &str = "The user sent this from their phone:";

/// The phone's messages handled here.
const TYPES: &[&str] = &["status", "control", "ask", "open", "close", "say", "unqueue", "launch", "listApps", "pushSub", "browse", "preview", "reveal", "input"];

pub fn handles(t: &str) -> bool {
    TYPES.contains(&t)
}

pub fn reason(text: &str) -> String {
    format!("{PHONE_PREFIX}\n\n{text}")
}

fn now_ms() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

fn line(v: Value) -> Out {
    Out::Line(v.to_string().into())
}

/// At most `max` characters, cut on a character boundary.
fn cut(s: &str, max: usize) -> String {
    match s.char_indices().nth(max) {
        Some((i, _)) => format!("{}…", &s[..i]),
        None => s.to_string(),
    }
}

// ── What the hooks say about the sessions ──────────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
struct Sess {
    pill: String,
    cwd: String,
    /// idle, working, needsYou or gone.
    state: &'static str,
    last_ms: u64,
    /// Claude Code itself (in a terminal, VS Code's or Cursor's): the only sessions that take messages.
    claude: bool,
    transcript: Option<PathBuf>,
}

struct Launch {
    id: String,
    folder: String,
    at_ms: u64,
    tx: mpsc::Sender<Out>,
}

#[derive(Default)]
struct Book {
    sessions: HashMap<String, Sess>,
    /// Messages from the phone waiting for their session's Stop hook.
    inbox: HashMap<String, Vec<String>>,
    /// Folders Claude Code ran in, the latest first.
    projects: Vec<String>,
    launches: Vec<Launch>,
}

static BOOK: LazyLock<Mutex<Book>> = LazyLock::new(|| Mutex::new(Book::default()));

const LAUNCH_WAIT_MS: u64 = 120_000;
const MAX_PROJECTS: usize = 12;
const MAX_QUEUED: usize = 5;

/// The pill the island puts a session on (hooks.ts): an agent's own, Cursor's for Claude Code in Cursor's terminal,
/// else Claude Code's. The second value: Claude Code itself.
fn pill_of(payload: &Value) -> (String, bool) {
    let agent = payload["coucou_agent"].as_str().unwrap_or("").trim().to_lowercase();
    let valid = !agent.is_empty()
        && agent != "claude"
        && agent.len() <= 40
        && agent.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_');
    if valid {
        (format!("agent_{agent}"), false)
    } else if payload["term_editor"].as_str() == Some("cursor") {
        ("agent_cursor".into(), true)
    } else {
        ("integration_claude".into(), true)
    }
}

fn state_after(event: &str, payload: &Value) -> Option<&'static str> {
    match event {
        "SessionStart" | "Stop" => Some("idle"),
        "UserPromptSubmit" | "PreToolUse" | "PostToolUse" | "PreCompact" => Some("working"),
        "PermissionRequest" => Some("needsYou"),
        "Notification" => {
            let kind = payload["notification_type"].as_str().unwrap_or("");
            let text = payload["message"].as_str().unwrap_or("").to_lowercase();
            Some(if kind == "idle_prompt" || text.contains("waiting for your input") { "idle" } else { "needsYou" })
        }
        "SessionEnd" => Some("gone"),
        _ => None,
    }
}

fn valid_session_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 128 && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

fn same_folder(a: &str, b: &str) -> bool {
    let norm = |s: &str| s.trim_end_matches(['\\', '/']).replace('\\', "/");
    if cfg!(windows) {
        norm(a).eq_ignore_ascii_case(&norm(b))
    } else {
        norm(a) == norm(b)
    }
}

/// Every hook event (pipe.rs), before the island gets it.
pub fn observe(payload: &Value, event: &str) {
    let Some(sid) = payload["session_id"].as_str().filter(|s| valid_session_id(s)) else { return };
    let now = now_ms();
    let (pill, claude) = pill_of(payload);
    let cwd = payload["cwd"].as_str().unwrap_or("").to_string();
    let mut started: Option<(Launch, String)> = None;
    {
        let mut guard = BOOK.lock().unwrap();
        let book: &mut Book = &mut guard;
        let known = book.sessions.contains_key(sid);
        let entry = book.sessions.entry(sid.to_string()).or_insert_with(|| Sess {
            pill: pill.clone(),
            cwd: cwd.clone(),
            state: "idle",
            last_ms: now,
            claude,
            transcript: None,
        });
        if !cwd.is_empty() {
            entry.cwd = cwd.clone();
        }
        entry.pill = pill.clone();
        entry.claude = claude;
        entry.last_ms = now;
        if let Some(st) = state_after(event, payload) {
            entry.state = st;
        }
        if claude && !cwd.is_empty() && Path::new(&cwd).is_absolute() {
            book.projects.retain(|p| !same_folder(p, &cwd));
            book.projects.insert(0, cwd.clone());
            book.projects.truncate(MAX_PROJECTS);
        }
        book.launches.retain(|l| now.saturating_sub(l.at_ms) < LAUNCH_WAIT_MS);
        if !known && !cwd.is_empty() {
            if let Some(i) = book.launches.iter().position(|l| same_folder(&l.folder, &cwd)) {
                started = Some((book.launches.remove(i), pill.clone()));
            }
        }
        if event == "SessionEnd" {
            book.inbox.remove(sid);
        }
        // Old sessions that ended are forgotten (the book stays small).
        if book.sessions.len() > 200 {
            let cutoff = now.saturating_sub(6 * 3600 * 1000);
            book.sessions.retain(|_, s| s.state != "gone" || s.last_ms > cutoff);
        }
    }
    if let Some((launch, pill)) = started {
        let _ = launch.tx.try_send(line(json!({ "type": "started", "id": launch.id, "session": pill })));
    }
}

/// Claude Code's Stop asks (coucou-hook's stop_check): the phone's messages for this session, if any. Taken: Claude
/// goes on with them, so the session is working again.
pub fn stop_reply(payload: &Value) -> Option<String> {
    let sid = payload["session_id"].as_str()?;
    let mut book = BOOK.lock().unwrap();
    let list = book.inbox.remove(sid)?;
    if list.is_empty() {
        return None;
    }
    if let Some(s) = book.sessions.get_mut(sid) {
        s.state = "working";
    }
    crate::log::line("nyeko: a message from the phone went to Claude".to_string());
    Some(list.join("\n\n"))
}

/// The session the phone means: "pill|session", a session id, or a pill (its latest session that has not ended).
fn resolve(asked: &str) -> Option<(String, Sess)> {
    let book = BOOK.lock().unwrap();
    if let Some((_, sid)) = asked.split_once('|') {
        return book.sessions.get(sid).map(|s| (sid.to_string(), s.clone()));
    }
    if let Some(s) = book.sessions.get(asked) {
        return Some((asked.to_string(), s.clone()));
    }
    book.sessions
        .iter()
        .filter(|(_, s)| s.pill == asked && s.state != "gone")
        .max_by_key(|(_, s)| s.last_ms)
        .map(|(k, s)| (k.clone(), s.clone()))
}

fn queue(sid: &str, text: &str) {
    let mut book = BOOK.lock().unwrap();
    let list = book.inbox.entry(sid.to_string()).or_default();
    if list.len() < MAX_QUEUED {
        list.push(cut(text, 8000));
    }
}

fn queued(sid: &str) -> Vec<String> {
    BOOK.lock().unwrap().inbox.get(sid).map(|l| l.iter().map(|t| cut(t, 2000)).collect()).unwrap_or_default()
}

// ── The conversation (Claude Code's transcript) ────────────────────────────────────────────────────────────────────

fn claude_dir() -> Option<PathBuf> {
    if let Some(dir) = std::env::var_os("CLAUDE_CONFIG_DIR").map(PathBuf::from).filter(|p| p.is_dir()) {
        return Some(dir);
    }
    let home = std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })?;
    Some(PathBuf::from(home).join(".claude"))
}

/// The session's transcript: Claude Code keeps it in a folder named after the working directory (every character but
/// letters and digits becomes '-'); the other folders are looked through when that one does not have it.
fn find_transcript(sid: &str, cwd: &str) -> Option<PathBuf> {
    if !valid_session_id(sid) {
        return None;
    }
    let projects = claude_dir()?.join("projects");
    let file = format!("{sid}.jsonl");
    let guess: String = cwd.chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '-' }).collect();
    if !guess.is_empty() {
        let direct = projects.join(&guess).join(&file);
        if direct.is_file() {
            return Some(direct);
        }
    }
    for entry in std::fs::read_dir(&projects).ok()?.flatten() {
        let p = entry.path().join(&file);
        if p.is_file() {
            return Some(p);
        }
    }
    None
}

#[derive(Debug, Clone, PartialEq)]
pub struct Item {
    /// you, claude or tools.
    pub role: &'static str,
    pub text: String,
    pub phone: bool,
}

const TAIL_BYTES: u64 = 600_000;

fn read_items(path: &Path) -> Option<Vec<Item>> {
    let mut f = std::fs::File::open(path).ok()?;
    let size = f.metadata().ok()?.len();
    let start = size.saturating_sub(TAIL_BYTES);
    f.seek(SeekFrom::Start(start)).ok()?;
    let mut data = Vec::new();
    f.read_to_end(&mut data).ok()?;
    Some(items(&data, start > 0))
}

/// The conversation in a transcript: what you asked, what Claude answered, one short line per tool. Thinking, tool
/// output, subagents and Claude Code's own bookkeeping are left out. The same rules as SessionTranscript.swift.
pub fn items(data: &[u8], partial_first_line: bool) -> Vec<Item> {
    let mut lines: Vec<&[u8]> = data.split(|b| *b == b'\n').filter(|l| !l.is_empty()).collect();
    if partial_first_line && !lines.is_empty() {
        lines.remove(0);
    }
    let mut out: Vec<Item> = Vec::new();
    let add = |out: &mut Vec<Item>, role: &'static str, raw: &str, phone: bool| {
        let text = raw.trim();
        if text.is_empty() {
            return;
        }
        if role != "you" {
            if let Some(last) = out.last_mut() {
                if last.role == role {
                    last.text.push_str(if role == "tools" { "\n" } else { "\n\n" });
                    last.text.push_str(text);
                    return;
                }
            }
        }
        out.push(Item { role, text: text.to_string(), phone });
    };
    for raw in lines {
        let Ok(entry) = serde_json::from_slice::<Value>(raw) else { continue };
        let kind = entry["type"].as_str().unwrap_or("");
        if entry["isSidechain"].as_bool() == Some(true) {
            continue;
        }
        if kind != "assistant" {
            if let Some(phone) = phone_text(&entry) {
                add(&mut out, "you", &phone, true);
                continue;
            }
        }
        if entry["isMeta"].as_bool() == Some(true) {
            continue;
        }
        let message = &entry["message"];
        match kind {
            "user" => {
                for text in user_texts(&message["content"]) {
                    if text.starts_with("[Request interrupted") {
                        add(&mut out, "tools", "Stopped", false);
                    } else {
                        add(&mut out, "you", &text, false);
                    }
                }
            }
            "assistant" => {
                if let Some(text) = message["content"].as_str() {
                    add(&mut out, "claude", text, false);
                    continue;
                }
                for block in message["content"].as_array().map(Vec::as_slice).unwrap_or_default() {
                    match block["type"].as_str() {
                        Some("text") => add(&mut out, "claude", block["text"].as_str().unwrap_or(""), false),
                        Some("tool_use") => {
                            let name = block["name"].as_str().unwrap_or("");
                            let input = &block["input"];
                            if name == "ExitPlanMode" && input["plan"].is_string() {
                                add(&mut out, "claude", &format!("Plan:\n{}", input["plan"].as_str().unwrap_or("")), false);
                            } else {
                                add(&mut out, "tools", &tool_line(name, input), false);
                            }
                        }
                        _ => {}
                    }
                }
            }
            _ => {}
        }
    }
    out
}

fn phone_text(entry: &Value) -> Option<String> {
    let mut candidates: Vec<&str> = Vec::new();
    if let Some(s) = entry["content"].as_str() {
        candidates.push(s);
    }
    if let Some(s) = entry["message"]["content"].as_str() {
        candidates.push(s);
    }
    if let Some(blocks) = entry["message"]["content"].as_array() {
        candidates.extend(blocks.iter().filter_map(|b| b["text"].as_str()));
    }
    if let Some(a) = entry["attachment"].as_object() {
        candidates.extend(a.values().filter_map(Value::as_str));
    }
    for c in candidates {
        if let Some(i) = c.find(PHONE_PREFIX) {
            let rest = c[i + PHONE_PREFIX.len()..].trim();
            return (!rest.is_empty()).then(|| rest.to_string());
        }
    }
    None
}

fn between<'a>(s: &'a str, open: &str, close: &str) -> Option<&'a str> {
    let a = s.find(open)? + open.len();
    let b = s[a..].find(close)? + a;
    Some(&s[a..b])
}

fn strip_reminders(s: &str) -> String {
    let mut t = s.to_string();
    while let Some(open) = t.find("<system-reminder>") {
        match t[open..].find("</system-reminder>") {
            Some(rel) => t.replace_range(open..open + rel + "</system-reminder>".len(), ""),
            None => {
                t.truncate(open);
                break;
            }
        }
    }
    t
}

fn user_texts(content: &Value) -> Vec<String> {
    let mut raw: Vec<String> = Vec::new();
    if let Some(s) = content.as_str() {
        raw.push(s.to_string());
    } else if let Some(blocks) = content.as_array() {
        for b in blocks {
            match b["type"].as_str() {
                Some("text") => raw.push(b["text"].as_str().unwrap_or("").to_string()),
                Some("image") => raw.push("[image]".into()),
                _ => {}
            }
        }
    }
    raw.into_iter()
        .filter_map(|s| {
            let t = strip_reminders(&s).trim().to_string();
            if t.is_empty() {
                return None;
            }
            if t.starts_with("<command-name>") {
                let name = between(&t, "<command-name>", "</command-name>").unwrap_or("");
                let args = between(&t, "<command-args>", "</command-args>").unwrap_or("");
                let cmd = if name.starts_with('/') { name.to_string() } else { format!("/{name}") };
                return Some(if args.is_empty() { cmd } else { format!("{cmd} {args}") });
            }
            if t.starts_with("<bash-input>") {
                return Some(format!("! {}", between(&t, "<bash-input>", "</bash-input>").unwrap_or("")));
            }
            let skip = ["<local-command-", "<bash-stdout>", "<bash-stderr>", "<command-message>", "Caveat: "];
            if skip.iter().any(|p| t.starts_with(p)) {
                return None;
            }
            Some(t)
        })
        .collect()
}

fn tool_line(name: &str, input: &Value) -> String {
    let s = |k: &str| input[k].as_str().unwrap_or("").to_string();
    let file = |k: &str| {
        let p = s(k);
        p.rsplit(['/', '\\']).next().unwrap_or("").to_string()
    };
    let short = |v: String, n: usize| {
        let first = v.lines().next().unwrap_or("").to_string();
        if first.chars().count() > n {
            format!("{}…", first.chars().take(n).collect::<String>())
        } else {
            first
        }
    };
    match name {
        "Bash" | "PowerShell" => format!("Ran {}", short(s("command"), 80)),
        "Read" => format!("Read {}", file("file_path")),
        "Edit" | "MultiEdit" => format!("Edited {}", file("file_path")),
        "Write" => format!("Wrote {}", file("file_path")),
        "NotebookEdit" => format!("Edited {}", file("notebook_path")),
        "Grep" => format!("Searched for {}", short(s("pattern"), 50)),
        "Glob" => format!("Looked for {}", short(s("pattern"), 50)),
        "WebFetch" => {
            let url = s("url");
            let host = url.split("://").nth(1).and_then(|r| r.split('/').next()).filter(|h| !h.is_empty());
            format!("Opened {}", host.unwrap_or("a web page"))
        }
        "WebSearch" => format!("Searched the web for {}", short(s("query"), 60)),
        "Task" | "Agent" => format!("Agent: {}", short(s("description"), 60)),
        "TodoWrite" => "Updated its to-do list".into(),
        "AskUserQuestion" => "Asked you a question".into(),
        _ => {
            let parts: Vec<&str> = name.split("__").collect();
            if parts.len() >= 3 && parts[0] == "mcp" {
                format!("{} ({})", parts[2..].join("__"), parts[1])
            } else {
                name.to_string()
            }
        }
    }
}

/// The items the phone gets: the last ones, each cut to a readable length, the whole under `max_bytes` of text.
pub fn for_phone(items: &[Item], max_items: usize, max_bytes: usize) -> Vec<Value> {
    let start = items.len().saturating_sub(max_items);
    let mut list: Vec<Value> = items[start..]
        .iter()
        .map(|item| {
            let mut text = item.text.clone();
            if item.role == "tools" {
                let lines: Vec<&str> = text.lines().collect();
                if lines.len() > 12 {
                    text = format!("… {} more\n{}", lines.len() - 12, lines[lines.len() - 12..].join("\n"));
                }
            } else {
                text = cut(&text, 4000);
            }
            let mut v = json!({ "r": item.role, "t": text });
            if item.phone {
                v["p"] = json!(true);
            }
            v
        })
        .collect();
    let size = |v: &Value| v["t"].as_str().map_or(0, str::len) + 24;
    let mut total: usize = list.iter().map(size).sum();
    while total > max_bytes && list.len() > 1 {
        total -= size(&list.remove(0));
    }
    list
}

fn folder_name(path: &str) -> String {
    path.trim_end_matches(['\\', '/']).rsplit(['\\', '/']).next().unwrap_or("").to_string()
}

/// The "chat" line for a session the phone has open.
fn chat_line(asked: &str) -> Value {
    let mut v = json!({ "type": "chat", "session": asked });
    let Some((sid, s)) = resolve(asked) else {
        v["state"] = json!("gone");
        v["readable"] = json!(false);
        v["canMessage"] = json!(false);
        v["items"] = json!([]);
        v["queued"] = json!([]);
        return v;
    };
    let path = s.transcript.clone().or_else(|| {
        let found = find_transcript(&sid, &s.cwd);
        if let Some(p) = &found {
            if let Some(entry) = BOOK.lock().unwrap().sessions.get_mut(&sid) {
                entry.transcript = Some(p.clone());
            }
        }
        found
    });
    let items = path.as_deref().and_then(read_items);
    let folder = folder_name(&s.cwd);
    v["title"] = json!(folder);
    v["folder"] = json!(folder);
    v["host"] = json!("");
    v["state"] = json!(s.state);
    v["canMessage"] = json!(s.claude && s.state != "gone");
    v["delivery"] = json!(if s.state == "idle" { "tab" } else { "wait" });
    v["note"] = json!("");
    v["readable"] = json!(items.is_some());
    v["items"] = json!(for_phone(items.as_deref().unwrap_or_default(), 60, 44_000));
    v["queued"] = json!(queued(&sid));
    v
}

/// A message to a session: typed in when Claude is idle, else kept for the Stop hook. (result, note)
fn say(asked: &str, text: &str) -> (&'static str, String) {
    let Some((sid, s)) = resolve(asked) else { return ("failed", "That session is not running any more.".into()) };
    if !s.claude || s.state == "gone" {
        return ("failed", "Only Claude Code sessions take messages from the phone.".into());
    }
    if s.state != "idle" {
        queue(&sid, text);
        let note = if s.state == "needsYou" {
            "Claude is waiting for you: answer it first. Your message goes to Claude when its turn ends."
        } else {
            "It goes to Claude when it finishes this turn."
        };
        return ("queued", note.into());
    }
    // Idle: its window comes forward and the message is typed in, on one line (a terminal would send each line).
    let one_line = crate::launch::clean_prompt(text);
    let folder = crate::session_window::folder_name(&s.cwd).to_string();
    let focused = crate::herdr::focus(&sid)
        || crate::session_window::lookup(&sid).is_some_and(|owners| crate::platform::focus_session_window(&owners, &folder));
    if focused {
        std::thread::sleep(Duration::from_millis(250));
        if crate::flow::paste::paste(&one_line, cfg!(target_os = "linux")) == crate::flow::paste::Outcome::Pasted {
            std::thread::sleep(Duration::from_millis(150));
            if crate::flow::os::send_enter().is_ok() {
                if let Some(entry) = BOOK.lock().unwrap().sessions.get_mut(&sid) {
                    entry.state = "working";
                }
                crate::log::line("nyeko: typed a message from the phone into a session".to_string());
                let note = if text.trim().contains('\n') { "Sent to Claude, as one line." } else { "" };
                return ("typed", note.into());
            }
            return ("typed", "It is typed in: press Enter on the computer to send it.".into());
        }
    }
    queue(&sid, text);
    ("queued", "Nyeko could not type into its window: it goes to Claude the next time Claude stops.".into())
}

// ── The computer ───────────────────────────────────────────────────────────────────────────────────────────────────

fn short_id(text: &str) -> String {
    let d = ring::digest::digest(&ring::digest::SHA256, text.as_bytes());
    d.as_ref()[..8].iter().map(|b| format!("{b:02x}")).collect()
}

fn projects() -> Vec<String> {
    BOOK.lock().unwrap().projects.clone()
}

/// The "mac" card (the name is Nyeko's message type; `os` says what this computer is).
fn status(name: &str) -> Value {
    let list: Vec<Value> = projects()
        .iter()
        .take(10)
        .map(|p| {
            let parent = Path::new(p).parent().map(|x| x.to_string_lossy().to_string()).unwrap_or_default();
            json!({ "id": short_id(p), "name": folder_name(p), "where": parent })
        })
        .collect();
    let mut v = json!({
        "type": "mac", "os": std::env::consts::OS, "name": name, "apps": [], "projects": list, "recording": false,
    });
    if let Some(cid) = super::pairing::known_computer_id() {
        v["cid"] = cid.into();
    }
    if let Some((percent, charging)) = sys::battery() {
        v["battery"] = json!({ "percent": percent, "charging": charging });
    }
    if let Some((volume, muted)) = sys::volume() {
        v["volume"] = json!(volume);
        v["muted"] = json!(muted);
    }
    if let Some(np) = sys::now_playing() {
        v["nowPlaying"] = json!({ "title": np.0, "artist": np.1, "source": np.2, "playing": np.3 });
    }
    v
}

/// One action on this computer. A note for the phone when something went wrong.
fn control(action: &str, app: &str) -> Option<String> {
    crate::log::line(format!("nyeko: {action}"));
    match action {
        "playPause" | "next" | "previous" => sys::media(action),
        "volumeUp" => sys::change_volume(0.06),
        "volumeDown" => sys::change_volume(-0.06),
        "mute" => sys::toggle_mute(),
        "lock" => sys::lock(),
        "displaySleep" => sys::display_sleep(),
        "sleep" => sys::sleep(),
        "restart" => sys::power(true),
        "shutdown" => sys::power(false),
        "screenshot" => sys::screenshot(),
        "openAny" => {
            let apps = sys::apps();
            match apps.iter().find(|(id, _, _)| id == app) {
                Some((_, _, path)) => sys::open_app(path),
                None => Some("That app is not on this computer any more.".into()),
            }
        }
        "focus" => {
            let Some((sid, s)) = resolve(app) else { return Some("That session is not running any more.".into()) };
            let folder = crate::session_window::folder_name(&s.cwd).to_string();
            let found = crate::herdr::focus(&sid)
                || crate::session_window::lookup(&sid).is_some_and(|owners| crate::platform::focus_session_window(&owners, &folder));
            (!found).then(|| "Its window could not be found.".to_string())
        }
        _ => Some("This computer can't do that.".into()),
    }
}

/// Nyo's chat on this computer: the few words it knows.
fn ask(text: &str) -> String {
    let t = text.to_lowercase();
    let has = |w: &[&str]| w.iter().any(|x| t.contains(x));
    let (action, said) = if has(&["pause", "stop the music", "stop music"]) {
        ("playPause", "Done: play/pause.")
    } else if has(&["screen off", "display off"]) {
        ("displaySleep", "Screen off.")
    } else if has(&["play", "resume"]) {
        ("playPause", "Done: play/pause.")
    } else if has(&["next", "skip"]) {
        ("next", "Next track.")
    } else if has(&["previous", "back"]) {
        ("previous", "Previous track.")
    } else if has(&["unmute", "mute"]) {
        ("mute", "Sound muted or back on.")
    } else if has(&["louder", "volume up", "turn it up"]) {
        ("volumeUp", "Louder.")
    } else if has(&["quieter", "volume down", "turn it down", "softer"]) {
        ("volumeDown", "Quieter.")
    } else if has(&["lock"]) {
        ("lock", "Locked.")
    } else if has(&["screenshot", "screen shot"]) {
        ("screenshot", "Screenshot taken.")
    } else {
        return "On this computer Nyo knows: play, pause, next, previous, louder, quieter, mute, lock, screen off and screenshot. For anything else, start a coding session.".into();
    };
    match control(action, "") {
        Some(problem) => problem,
        None => said.into(),
    }
}

// ── One phone's connection ─────────────────────────────────────────────────────────────────────────────────────────

pub struct Conn {
    tx: mpsc::Sender<Out>,
    name: String,
    open: Arc<Mutex<Option<String>>>,
    generation: Arc<AtomicU64>,
    ended: Arc<AtomicBool>,
}

impl Conn {
    pub fn new(tx: mpsc::Sender<Out>, name: String) -> Self {
        Self { tx, name, open: Arc::new(Mutex::new(None)), generation: Arc::new(AtomicU64::new(0)), ended: Arc::new(AtomicBool::new(false)) }
    }

    /// The connection ended: its session watch stops.
    pub fn end(&self) {
        self.ended.store(true, Ordering::SeqCst);
        *self.open.lock().unwrap() = None;
    }

    fn send_status_later(&self, delay_ms: u64) {
        let (tx, name) = (self.tx.clone(), self.name.clone());
        tokio::spawn(async move {
            if delay_ms > 0 {
                tokio::time::sleep(Duration::from_millis(delay_ms)).await;
            }
            if let Ok(v) = tokio::task::spawn_blocking(move || status(&name)).await {
                let _ = tx.try_send(line(v));
            }
        });
    }

    fn notice(&self, text: String) {
        // Shown on the phone as Nyo's answer to nothing: the web app and the Android app show "reply" lines it did
        // not wait for only in Nyo's chat, so a failed control says why through "said" instead (a toast).
        let _ = self.tx.try_send(line(json!({ "type": "said", "id": "", "result": "failed", "note": cut(&text, 300) })));
    }

    pub fn handle(&self, msg: &Value) {
        let text = |k: &str, max: usize| msg[k].as_str().filter(|s| s.len() <= max).unwrap_or("").to_string();
        match msg["type"].as_str().unwrap_or("") {
            "status" => self.send_status_later(0),
            "listApps" => {
                let tx = self.tx.clone();
                tokio::spawn(async move {
                    let apps = tokio::task::spawn_blocking(sys::apps).await.unwrap_or_default();
                    let list: Vec<Value> = apps.iter().take(400).map(|(id, name, _)| json!({ "id": id, "name": name })).collect();
                    let _ = tx.try_send(line(json!({ "type": "apps", "apps": list })));
                });
            }
            "control" => {
                let action = text("action", 40);
                let app = text("app", 300);
                if action.is_empty() {
                    return;
                }
                let (tx, name) = (self.tx.clone(), self.name.clone());
                let me = self.clone_sender();
                tokio::spawn(async move {
                    let a = action.clone();
                    let problem = tokio::task::spawn_blocking(move || control(&a, &app)).await.ok().flatten();
                    if let Some(p) = problem {
                        me.notice(p);
                    }
                    tokio::time::sleep(Duration::from_millis(400)).await;
                    if let Ok(v) = tokio::task::spawn_blocking(move || status(&name)).await {
                        let _ = tx.try_send(line(v));
                    }
                });
            }
            "ask" => {
                let id = text("id", 64);
                let words = cut(msg["text"].as_str().unwrap_or(""), 4000);
                if words.trim().is_empty() {
                    return;
                }
                let tx = self.tx.clone();
                tokio::spawn(async move {
                    let answer = tokio::task::spawn_blocking(move || ask(&words)).await.unwrap_or_default();
                    let _ = tx.try_send(line(json!({ "type": "reply", "id": id, "text": answer })));
                });
            }
            "open" => {
                let session = text("session", 260);
                if session.is_empty() {
                    return;
                }
                *self.open.lock().unwrap() = Some(session);
                self.watch();
            }
            "close" => {
                *self.open.lock().unwrap() = None;
                self.generation.fetch_add(1, Ordering::SeqCst);
            }
            "unqueue" => {
                if let Some((sid, _)) = resolve(&text("session", 260)) {
                    BOOK.lock().unwrap().inbox.remove(&sid);
                }
            }
            "say" => {
                let session = text("session", 260);
                let id = text("id", 64);
                let words = msg["text"].as_str().unwrap_or("").trim().to_string();
                if session.is_empty() || words.is_empty() || words.chars().count() > 60_000 {
                    return;
                }
                let tx = self.tx.clone();
                tokio::spawn(async move {
                    let (result, note) = tokio::task::spawn_blocking(move || say(&session, &words))
                        .await
                        .unwrap_or(("failed", "Something went wrong.".into()));
                    let _ = tx.try_send(line(json!({ "type": "said", "id": id, "result": result, "note": note })));
                });
            }
            "launch" => {
                let id = text("id", 64);
                let project = text("project", 64);
                let prompt = cut(msg["prompt"].as_str().unwrap_or(""), 8000);
                // A recent project by its id, or (Nyeko) a folder the phone browsed to, inside the home folder (files.rs).
                let browsed = msg["folder"].as_str().map(super::files::launch_folder);
                let from_phone = browsed.is_some();
                let picked = match browsed {
                    Some(f) => f,
                    None => projects().into_iter().find(|p| short_id(p) == project),
                };
                let Some(folder) = picked else {
                    let note = if from_phone { "Nyeko only starts sessions in a folder inside your home folder." }
                               else { "Nyeko only starts sessions in folders it has seen Claude Code work in." };
                    let _ = self.tx.try_send(line(json!({ "type": "launched", "id": id, "ok": false, "note": note })));
                    return;
                };
                let tx = self.tx.clone();
                tokio::spawn(async move {
                    let f = folder.clone();
                    let ok = tokio::task::spawn_blocking(move || crate::launch::launch_session(f, prompt)).await.unwrap_or(false);
                    if ok {
                        BOOK.lock().unwrap().launches.push(Launch { id: id.clone(), folder, at_ms: now_ms(), tx: tx.clone() });
                    }
                    let note = if ok { "" } else { "No terminal could be opened in that folder." };
                    let _ = tx.try_send(line(json!({ "type": "launched", "id": id, "ok": ok, "note": note })));
                });
            }
            "browse" => {
                // A folder in the home folder, read-only (files.rs; docs/PHONE_FILES.md).
                let id = text("id", 64);
                let asked = msg["path"].as_str().map(str::to_string);
                let tx = self.tx.clone();
                tokio::spawn(async move {
                    let mut out = tokio::task::spawn_blocking(move || match super::files::resolve(asked.as_deref()) {
                        Some(dir) => super::files::listing(&dir),
                        None => json!({ "ok": false, "note": "Nyeko only shows what is in your home folder." }),
                    }).await.unwrap_or_else(|_| json!({ "ok": false }));
                    out["type"] = json!("folder");
                    out["id"] = json!(id);
                    let _ = tx.send(line(out)).await;
                });
            }
            "preview" => {
                let id = text("id", 64);
                let asked = msg["path"].as_str().map(str::to_string);
                let tx = self.tx.clone();
                tokio::spawn(async move {
                    let (mut header, chunks) = tokio::task::spawn_blocking(move || {
                        let home = super::files::home();
                        match super::files::resolve(asked.as_deref()) {
                            Some(p) if Some(&p) != home.as_ref() => super::files::preview(&p),
                            _ => (json!({ "ok": false, "note": "Nyeko only shows what is in your home folder." }), vec![]),
                        }
                    }).await.unwrap_or_else(|_| (json!({ "ok": false }), vec![]));
                    header["type"] = json!("file");
                    header["id"] = json!(id);
                    if tx.send(line(header)).await.is_err() {
                        return;
                    }
                    // In order, waiting for room: a big image is about a hundred lines.
                    for (i, d) in chunks.into_iter().enumerate() {
                        if tx.send(line(json!({ "type": "chunk", "id": id, "i": i, "d": d }))).await.is_err() {
                            return;
                        }
                    }
                });
            }
            "input" => {
                // The phone as trackpad and keyboard (remote_input.rs; docs/REMOTE_INPUT.md).
                let events = msg["e"].as_array().cloned().unwrap_or_default();
                if events.iter().any(|e| e["k"] == "hello") {
                    let ok = super::remote_input::supported();
                    let note = if ok { "" } else { "The trackpad works with Windows and Macs for now." };
                    let _ = self.tx.try_send(line(json!({ "type": "inputState", "ok": ok, "note": note })));
                }
                super::remote_input::handle(&events);
            }
            "reveal" => {
                // Shows a file or folder in the file manager: selected, never opened.
                if let Some(p) = super::files::resolve(msg["path"].as_str()) {
                    tokio::task::spawn_blocking(move || reveal(&p));
                }
            }
            _ => {} // pushSub: this computer sends no Web Push
        }
    }

    fn clone_sender(&self) -> Conn {
        Conn { tx: self.tx.clone(), name: self.name.clone(), open: self.open.clone(), generation: self.generation.clone(), ended: self.ended.clone() }
    }

    /// While a session is open on the phone, its conversation is sent whenever it changes (read every 3 s).
    fn watch(&self) {
        let gen = self.generation.fetch_add(1, Ordering::SeqCst) + 1;
        let (tx, open, generation, ended) = (self.tx.clone(), self.open.clone(), self.generation.clone(), self.ended.clone());
        tokio::spawn(async move {
            let mut last = String::new();
            loop {
                if ended.load(Ordering::SeqCst) || generation.load(Ordering::SeqCst) != gen || tx.is_closed() {
                    break;
                }
                let Some(asked) = open.lock().unwrap().clone() else { break };
                let text = tokio::task::spawn_blocking(move || chat_line(&asked).to_string()).await.unwrap_or_default();
                if generation.load(Ordering::SeqCst) != gen {
                    break;
                }
                if !text.is_empty() && text != last && tx.try_send(Out::Line(text.clone().into())).is_ok() {
                    last = text;
                }
                tokio::time::sleep(Duration::from_secs(3)).await;
            }
        });
    }
}

// ── The operating system ───────────────────────────────────────────────────────────────────────────────────────────

/// Shows a file or folder in Explorer (selected) or the Linux file manager (its folder).
fn reveal(path: &std::path::Path) {
    #[cfg(windows)]
    {
        let mut cmd = std::process::Command::new("explorer.exe");
        if path.is_dir() { cmd.arg(path); } else { cmd.arg(format!("/select,{}", path.display())); }
        let _ = cmd.spawn();
    }
    #[cfg(not(windows))]
    {
        let dir = if path.is_dir() { path } else { path.parent().unwrap_or(path) };
        let _ = std::process::Command::new("xdg-open").arg(dir).spawn();
    }
}

/// A command that must not flash a window, run to its end (a few seconds at most for these).
fn run(program: &str, args: &[&str]) -> bool {
    let mut cmd = std::process::Command::new(program);
    cmd.args(args);
    crate::platform::no_console(&mut cmd);
    cmd.status().is_ok_and(|s| s.success())
}

#[cfg_attr(windows, allow(dead_code))]
fn output(program: &str, args: &[&str]) -> Option<String> {
    let mut cmd = std::process::Command::new(program);
    cmd.args(args);
    crate::platform::no_console(&mut cmd);
    let out = cmd.output().ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).to_string())
}

#[cfg(windows)]
mod sys {
    use std::path::{Path, PathBuf};

    use windows::Media::Control::{
        GlobalSystemMediaTransportControlsSessionManager as Manager,
        GlobalSystemMediaTransportControlsSessionPlaybackStatus as Status,
    };
    use windows::Win32::Media::Audio::Endpoints::IAudioEndpointVolume;
    use windows::Win32::Media::Audio::{eMultimedia, eRender, IMMDeviceEnumerator, MMDeviceEnumerator};
    use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CLSCTX_ALL, COINIT_MULTITHREADED};
    use windows::Win32::System::Power::{GetSystemPowerStatus, SYSTEM_POWER_STATUS};

    use super::{run, short_id};

    fn com() {
        unsafe {
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        }
    }

    fn endpoint() -> Option<IAudioEndpointVolume> {
        com();
        unsafe {
            let devices = CoCreateInstance::<_, IMMDeviceEnumerator>(&MMDeviceEnumerator, None, CLSCTX_ALL).ok()?;
            let device = devices.GetDefaultAudioEndpoint(eRender, eMultimedia).ok()?;
            device.Activate::<IAudioEndpointVolume>(CLSCTX_ALL, None).ok()
        }
    }

    pub fn volume() -> Option<(u32, bool)> {
        let v = endpoint()?;
        unsafe {
            let level = v.GetMasterVolumeLevelScalar().ok()?;
            let muted = v.GetMute().map(|b| b.as_bool()).unwrap_or(false);
            Some(((level * 100.0).round().clamp(0.0, 100.0) as u32, muted))
        }
    }

    pub fn change_volume(delta: f32) -> Option<String> {
        let v = endpoint()?;
        unsafe {
            let level = v.GetMasterVolumeLevelScalar().ok()?;
            let _ = v.SetMasterVolumeLevelScalar((level + delta).clamp(0.0, 1.0), std::ptr::null());
            if delta > 0.0 {
                let _ = v.SetMute(false, std::ptr::null());
            }
        }
        None
    }

    pub fn toggle_mute() -> Option<String> {
        let v = endpoint()?;
        unsafe {
            let muted = v.GetMute().map(|b| b.as_bool()).unwrap_or(false);
            let _ = v.SetMute(!muted, std::ptr::null());
        }
        None
    }

    pub fn battery() -> Option<(u32, bool)> {
        let mut s = SYSTEM_POWER_STATUS::default();
        unsafe { GetSystemPowerStatus(&mut s).ok()? };
        // 128: no battery; 255: unknown.
        if s.BatteryFlag == 128 || s.BatteryLifePercent > 100 {
            return None;
        }
        Some((u32::from(s.BatteryLifePercent), s.ACLineStatus == 1))
    }

    fn media_session() -> Option<windows::Media::Control::GlobalSystemMediaTransportControlsSession> {
        com();
        let manager = Manager::RequestAsync().and_then(|op| op.get()).ok()?;
        manager.GetCurrentSession().ok()
    }

    pub fn now_playing() -> Option<(String, String, String, bool)> {
        let session = media_session()?;
        let props = session.TryGetMediaPropertiesAsync().and_then(|op| op.get()).ok()?;
        let title = props.Title().ok()?.to_string_lossy();
        if title.trim().is_empty() {
            return None;
        }
        let artist = props.Artist().map(|a| a.to_string_lossy()).unwrap_or_default();
        let app = session.SourceAppUserModelId().map(|a| a.to_string_lossy()).unwrap_or_default();
        // "Spotify.exe" → "Spotify"; "Microsoft.ZuneMusic_8wekyb3d8bbwe!Microsoft.ZuneMusic" → "ZuneMusic".
        let source = app.split('!').next().unwrap_or("").split('_').next().unwrap_or("").trim_end_matches(".exe");
        let source = source.rsplit('.').next().unwrap_or(source).to_string();
        let playing = session.GetPlaybackInfo().and_then(|i| i.PlaybackStatus()).is_ok_and(|s| s == Status::Playing);
        Some((title, artist, source, playing))
    }

    pub fn media(action: &str) -> Option<String> {
        let Some(session) = media_session() else { return Some("Nothing is playing on this computer.".into()) };
        let done = match action {
            "next" => session.TrySkipNextAsync().and_then(|op| op.get()),
            "previous" => session.TrySkipPreviousAsync().and_then(|op| op.get()),
            _ => session.TryTogglePlayPauseAsync().and_then(|op| op.get()),
        };
        (!done.unwrap_or(false)).then(|| "The player did not take it.".to_string())
    }

    fn powershell(script: &str) -> bool {
        run("powershell.exe", &["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script])
    }

    pub fn lock() -> Option<String> {
        (!run("rundll32.exe", &["user32.dll,LockWorkStation"])).then(|| "Windows did not lock.".to_string())
    }

    pub fn display_sleep() -> Option<String> {
        // WM_SYSCOMMAND / SC_MONITORPOWER / off, posted to every window (posted: a window that hangs cannot hold it up).
        let script = "Add-Type -Namespace Nyeko -Name Screen -MemberDefinition '[DllImport(\"user32.dll\")] public static extern bool PostMessage(int h, int m, int w, int l);'; [Nyeko.Screen]::PostMessage(0xFFFF, 0x0112, 0xF170, 2) | Out-Null";
        (!powershell(script)).then(|| "The screen did not turn off.".to_string())
    }

    pub fn sleep() -> Option<String> {
        let script = "Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.Application]::SetSuspendState('Suspend', $false, $false) | Out-Null";
        std::thread::spawn(move || powershell(script));
        None
    }

    pub fn power(restart: bool) -> Option<String> {
        // Five seconds: the phone gets its answer first. Open apps may still ask to save.
        let ok = run("shutdown.exe", &[if restart { "/r" } else { "/s" }, "/t", "5"]);
        (!ok).then(|| "Windows refused it.".to_string())
    }

    pub fn screenshot() -> Option<String> {
        let script = "Add-Type -AssemblyName System.Windows.Forms, System.Drawing; \
            $b = [System.Windows.Forms.SystemInformation]::VirtualScreen; \
            $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height; \
            $g = [System.Drawing.Graphics]::FromImage($bmp); \
            $g.CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size); \
            $d = Join-Path ([Environment]::GetFolderPath('MyPictures')) 'Screenshots'; \
            New-Item -ItemType Directory -Force -Path $d | Out-Null; \
            $bmp.Save((Join-Path $d ('Nyeko ' + (Get-Date -Format 'yyyy-MM-dd HH.mm.ss') + '.png')))";
        (!powershell(script)).then(|| "The screenshot failed.".to_string())
    }

    fn start_menus() -> Vec<PathBuf> {
        let mut out = Vec::new();
        for (var, tail) in [("ProgramData", r"Microsoft\Windows\Start Menu\Programs"), ("APPDATA", r"Microsoft\Windows\Start Menu\Programs")] {
            if let Some(base) = std::env::var_os(var) {
                out.push(PathBuf::from(base).join(tail));
            }
        }
        out
    }

    fn walk(dir: &Path, depth: usize, out: &mut Vec<PathBuf>) {
        let Ok(entries) = std::fs::read_dir(dir) else { return };
        for e in entries.flatten() {
            let p = e.path();
            if p.is_dir() {
                if depth < 4 {
                    walk(&p, depth + 1, out);
                }
            } else if p.extension().is_some_and(|x| x.eq_ignore_ascii_case("lnk")) {
                out.push(p);
            }
        }
    }

    /// The Start menu's shortcuts: (id, name, path), by name, without uninstallers and duplicates.
    pub fn apps() -> Vec<(String, String, String)> {
        let mut files = Vec::new();
        for dir in start_menus() {
            walk(&dir, 0, &mut files);
        }
        let mut seen = std::collections::HashSet::new();
        let mut out: Vec<(String, String, String)> = files
            .into_iter()
            .filter_map(|p| {
                let name = p.file_stem()?.to_string_lossy().to_string();
                let low = name.to_lowercase();
                if low.contains("uninstall") || low.contains("readme") || !seen.insert(low) {
                    return None;
                }
                let path = p.to_string_lossy().to_string();
                Some((short_id(&path), name, path))
            })
            .collect();
        out.sort_by_key(|(_, n, _)| n.to_lowercase());
        out
    }

    pub fn open_app(path: &str) -> Option<String> {
        let mut cmd = std::process::Command::new("explorer.exe");
        cmd.arg(path);
        crate::platform::no_console(&mut cmd);
        cmd.spawn().err().map(|_| "It did not open.".to_string())
    }
}

#[cfg(not(windows))]
mod sys {
    use super::{output, run, short_id};

    pub fn volume() -> Option<(u32, bool)> {
        // "Volume: 0.40 [MUTED]"
        let text = output("wpctl", &["get-volume", "@DEFAULT_AUDIO_SINK@"])?;
        let level: f32 = text.split_whitespace().nth(1)?.parse().ok()?;
        Some(((level * 100.0).round().clamp(0.0, 150.0) as u32, text.contains("MUTED")))
    }

    pub fn change_volume(delta: f32) -> Option<String> {
        let step = format!("{}%{}", (delta.abs() * 100.0).round() as u32, if delta > 0.0 { "+" } else { "-" });
        let ok = run("wpctl", &["set-volume", "-l", "1.0", "@DEFAULT_AUDIO_SINK@", &step])
            || run("pactl", &["set-sink-volume", "@DEFAULT_SINK@", &format!("{}{}%", if delta > 0.0 { "+" } else { "-" }, (delta.abs() * 100.0).round() as u32)]);
        (!ok).then(|| "The volume could not be changed (wpctl or pactl is needed).".to_string())
    }

    pub fn toggle_mute() -> Option<String> {
        let ok = run("wpctl", &["set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"]) || run("pactl", &["set-sink-mute", "@DEFAULT_SINK@", "toggle"]);
        (!ok).then(|| "The sound could not be muted (wpctl or pactl is needed).".to_string())
    }

    pub fn battery() -> Option<(u32, bool)> {
        let dir = std::fs::read_dir("/sys/class/power_supply").ok()?.flatten().map(|e| e.path()).find(|p| {
            std::fs::read_to_string(p.join("type")).is_ok_and(|t| t.trim() == "Battery")
        })?;
        let percent: u32 = std::fs::read_to_string(dir.join("capacity")).ok()?.trim().parse().ok()?;
        let status = std::fs::read_to_string(dir.join("status")).unwrap_or_default();
        Some((percent.min(100), status.trim() == "Charging" || status.trim() == "Full"))
    }

    pub fn now_playing() -> Option<(String, String, String, bool)> {
        let text = output("playerctl", &["metadata", "--format", "{{title}}\t{{artist}}\t{{playerName}}\t{{status}}"])?;
        let mut parts = text.trim().split('\t');
        let title = parts.next()?.to_string();
        if title.is_empty() {
            return None;
        }
        let artist = parts.next().unwrap_or("").to_string();
        let source = parts.next().unwrap_or("").to_string();
        let playing = parts.next() == Some("Playing");
        Some((title, artist, source, playing))
    }

    pub fn media(action: &str) -> Option<String> {
        let verb = match action {
            "next" => "next",
            "previous" => "previous",
            _ => "play-pause",
        };
        (!run("playerctl", &[verb])).then(|| "Nothing is playing (playerctl is needed).".to_string())
    }

    pub fn lock() -> Option<String> {
        (!run("loginctl", &["lock-session"])).then(|| "The session did not lock.".to_string())
    }

    pub fn display_sleep() -> Option<String> {
        (!run("xset", &["dpms", "force", "off"])).then(|| "The screen did not turn off.".to_string())
    }

    pub fn sleep() -> Option<String> {
        (!run("systemctl", &["suspend"])).then(|| "The computer did not go to sleep.".to_string())
    }

    pub fn power(restart: bool) -> Option<String> {
        (!run("systemctl", &[if restart { "reboot" } else { "poweroff" }])).then(|| "It was refused.".to_string())
    }

    pub fn screenshot() -> Option<String> {
        let ok = run("gnome-screenshot", &[]) || run("spectacle", &["-b", "-n"]);
        (!ok).then(|| "No screenshot tool was found.".to_string())
    }

    /// The desktop files: (id, name, desktop id).
    pub fn apps() -> Vec<(String, String, String)> {
        let mut dirs = vec![std::path::PathBuf::from("/usr/share/applications")];
        if let Some(home) = std::env::var_os("HOME") {
            dirs.push(std::path::PathBuf::from(home).join(".local/share/applications"));
        }
        let mut out: Vec<(String, String, String)> = Vec::new();
        let mut seen = std::collections::HashSet::new();
        for dir in dirs {
            let Ok(entries) = std::fs::read_dir(&dir) else { continue };
            for e in entries.flatten() {
                let p = e.path();
                if p.extension().and_then(|x| x.to_str()) != Some("desktop") {
                    continue;
                }
                let Ok(text) = std::fs::read_to_string(&p) else { continue };
                if text.lines().any(|l| l.trim() == "NoDisplay=true") {
                    continue;
                }
                let Some(name) = text.lines().find_map(|l| l.strip_prefix("Name=")).map(str::to_string) else { continue };
                let stem = p.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
                if seen.insert(name.to_lowercase()) {
                    out.push((short_id(&stem), name, stem));
                }
            }
        }
        out.sort_by_key(|(_, n, _)| n.to_lowercase());
        out
    }

    pub fn open_app(stem: &str) -> Option<String> {
        let mut cmd = std::process::Command::new("gtk-launch");
        cmd.arg(stem);
        crate::platform::no_console(&mut cmd);
        cmd.spawn().err().map(|_| "It did not open.".to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_transcript_reads_as_a_conversation_with_the_phones_messages_marked() {
        let lines = [
            r#"{"type":"user","message":{"content":"fix the build"}}"#,
            r#"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"Looking."},{"type":"tool_use","name":"Bash","input":{"command":"cargo build\nmore"}},{"type":"tool_use","name":"Edit","input":{"file_path":"C:\\code\\src\\main.rs"}}]}}"#,
            r#"{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}"#,
            r#"{"type":"assistant","isSidechain":true,"message":{"content":"sub agent"}}"#,
            r#"{"type":"user","isMeta":true,"message":{"content":"<local-command-stdout>x</local-command-stdout>"}}"#,
            r#"{"type":"attachment","attachment":{"type":"hook","content":"The user sent this from their phone:\n\nship it"}}"#,
            r#"{"type":"user","message":{"content":"<command-name>/clear</command-name><command-args></command-args>"}}"#,
        ];
        let got = items(lines.join("\n").as_bytes(), false);
        let roles: Vec<&str> = got.iter().map(|i| i.role).collect();
        assert_eq!(roles, ["you", "claude", "tools", "you", "you"]);
        assert_eq!(got[2].text, "Ran cargo build\nEdited main.rs");
        assert!(got[3].phone && got[3].text == "ship it");
        assert_eq!(got[4].text, "/clear");
        // A cut first line is skipped.
        assert_eq!(items(b"{\"broken\n{\"type\":\"user\",\"message\":{\"content\":\"hi\"}}", true).len(), 1);
    }

    #[test]
    fn the_phone_gets_the_end_within_its_size() {
        let many: Vec<Item> = (0..100).map(|i| Item { role: if i % 2 == 0 { "you" } else { "claude" }, text: "x".repeat(3000), phone: false }).collect();
        let list = for_phone(&many, 60, 44_000);
        assert!(list.len() <= 60 && list.len() > 1);
        assert!(list.iter().map(|v| v["t"].as_str().unwrap().len() + 24).sum::<usize>() <= 44_000);
        let long = [Item { role: "claude", text: "é".repeat(5000), phone: false }];
        assert_eq!(for_phone(&long, 60, 44_000)[0]["t"].as_str().unwrap().chars().count(), 4001);
    }

    #[test]
    fn sessions_follow_their_hooks_and_the_phones_message_waits_for_stop() {
        let sid = "nyeko-test-session-1";
        let cwd = if cfg!(windows) { r"C:\code\nyeko-test" } else { "/code/nyeko-test" };
        observe(&json!({ "session_id": sid, "cwd": cwd, "hook_event_name": "UserPromptSubmit" }), "UserPromptSubmit");
        let (found, s) = resolve("integration_claude").expect("by its pill");
        assert_eq!(found, sid);
        assert_eq!(s.state, "working");
        assert!(projects().iter().any(|p| same_folder(p, cwd)));
        // Working: kept for the Stop hook, which takes it once.
        let (result, _) = say(&format!("integration_claude|{sid}"), "and add a test");
        assert_eq!(result, "queued");
        assert_eq!(queued(sid), vec!["and add a test".to_string()]);
        assert_eq!(stop_reply(&json!({ "session_id": sid })).as_deref(), Some("and add a test"));
        assert_eq!(stop_reply(&json!({ "session_id": sid })), None);
        assert!(reason("hi").starts_with(PHONE_PREFIX));
        // Another agent's session takes no message.
        observe(&json!({ "session_id": "nyeko-test-codex", "coucou_agent": "codex", "cwd": cwd }), "UserPromptSubmit");
        assert_eq!(say("nyeko-test-codex", "hello").0, "failed");
        observe(&json!({ "session_id": sid }), "SessionEnd");
        assert_eq!(resolve(sid).unwrap().1.state, "gone");
        // Not a session id: never a path.
        assert!(find_transcript("../../etc/passwd", cwd).is_none());
    }

    #[test]
    fn nyo_knows_a_few_words_and_says_what_it_knows() {
        assert!(ask("what's the weather").contains("Nyo knows"));
        assert!(handles("listApps") && handles("say") && !handles("decision"));
        assert_eq!(short_id("C:\\code").len(), 16);
        assert_eq!(folder_name("C:\\code\\coucou\\"), "coucou");
    }
}
