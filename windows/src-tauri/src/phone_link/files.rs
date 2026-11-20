//! Nyeko: the phone looks through the folders in your home folder, previews a file, and starts a session in a folder
//! (docs/PHONE_FILES.md). Read-only: nothing here writes, moves or opens a file. Only inside the home folder, after
//! links are followed; hidden files (dotfiles, so .env and .ssh too, and Windows' hidden ones such as AppData) are never
//! listed or read. The same rules and messages as the Mac (NotchBuddy/Sources/App/PhoneWeb/NyekoFiles.swift).

use std::path::{Path, PathBuf};

use serde_json::{json, Value};

/// Entries in one listing, at most.
pub const MAX_ENTRIES: usize = 300;
/// A text file is sent up to this size (the rest is cut); an image up to the other.
pub const MAX_TEXT: usize = 256 * 1024;
pub const MAX_BINARY: usize = 4 * 1024 * 1024;
/// Bytes per chunk line: 48 KB of base64 in a line of at most 64 KB.
pub const CHUNK: usize = 36_000;

const TEXT: &[&str] = &["txt", "md", "markdown", "json", "jsonc", "yml", "yaml", "toml", "xml", "csv", "tsv", "log", "ini", "cfg",
    "conf", "swift", "rs", "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "rb", "go", "java", "kt", "kts", "c", "h", "cc", "cpp", "hpp",
    "m", "mm", "cs", "php", "sh", "bash", "zsh", "fish", "ps1", "bat", "cmd", "sql", "html", "htm", "css", "scss", "less", "vue",
    "svelte", "lua", "r", "dart", "gradle", "properties", "plist", "tex", "srt", "vtt"];
const IMAGES: &[(&str, &str)] = &[("png", "image/png"), ("jpg", "image/jpeg"), ("jpeg", "image/jpeg"), ("gif", "image/gif"),
    ("webp", "image/webp"), ("heic", "image/heic"), ("bmp", "image/bmp"), ("svg", "image/svg+xml")];

pub fn home() -> Option<PathBuf> {
    let raw = std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })?;
    std::fs::canonicalize(raw).ok().map(|p| plain(&p))
}

/// Windows' canonical paths start with \\?\: without it, a terminal and the phone read them as usual.
fn plain(p: &Path) -> PathBuf {
    let s = p.to_string_lossy();
    match s.strip_prefix(r"\\?\") {
        Some(rest) if rest.as_bytes().get(1) == Some(&b':') => PathBuf::from(rest),
        _ => p.to_path_buf(),
    }
}

fn hidden(meta: &std::fs::Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        meta.file_attributes() & 0x2 != 0 // FILE_ATTRIBUTE_HIDDEN
    }
    #[cfg(not(windows))]
    {
        let _ = meta;
        false
    }
}

/// Inside `home` (or `home` itself), with no hidden part on the way.
pub fn allowed(path: &Path, home: &Path) -> bool {
    let Ok(rest) = path.strip_prefix(home) else { return false };
    let mut walked = home.to_path_buf();
    for part in rest.components() {
        let name = part.as_os_str().to_string_lossy();
        if name.starts_with('.') {
            return false;
        }
        walked.push(part);
        if std::fs::symlink_metadata(&walked).is_ok_and(|m| hidden(&m)) {
            return false;
        }
    }
    true
}

/// The real path the phone may use, or None: empty means the home folder; "~" is expanded; links are followed.
pub fn resolve(asked: Option<&str>) -> Option<PathBuf> {
    resolve_in(asked, &home()?)
}

/// resolve() against a given home folder (the tests use their own: another test points the real one elsewhere).
pub fn resolve_in(asked: Option<&str>, home: &Path) -> Option<PathBuf> {
    let home = home.to_path_buf();
    let raw = asked.unwrap_or("").trim();
    if raw.len() > 4096 || raw.contains('\0') {
        return None;
    }
    if raw.is_empty() || raw == "~" {
        return Some(home);
    }
    let expanded = match raw.strip_prefix("~/").or_else(|| raw.strip_prefix("~\\")) {
        Some(rest) => home.join(rest),
        None => PathBuf::from(raw),
    };
    if !expanded.is_absolute() {
        return None;
    }
    let real = plain(&std::fs::canonicalize(&expanded).ok()?);
    allowed(&real, &home).then_some(real)
}

/// "~/Projects/app" (or "~\Projects\app") for the phone.
pub fn display(path: &Path, home: &Path) -> String {
    match path.strip_prefix(home) {
        Ok(rest) if rest.as_os_str().is_empty() => "~".into(),
        Ok(rest) => format!("~{}{}", std::path::MAIN_SEPARATOR, rest.display()),
        Err(_) => path.display().to_string(),
    }
}

fn ext(path: &Path) -> String {
    path.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default()
}

fn mime(path: &Path) -> Option<&'static str> {
    let e = ext(path);
    IMAGES.iter().find(|(x, _)| *x == e).map(|(_, m)| *m)
}

/// text, image or other: by the name, and for a name without an extension by a look at the first bytes.
pub fn kind(path: &Path) -> &'static str {
    let e = ext(path);
    if mime(path).is_some() {
        return "image";
    }
    let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    if TEXT.contains(&e.as_str()) || ["Makefile", "Dockerfile", "README", "LICENSE"].contains(&name.as_str()) {
        return "text";
    }
    if !e.is_empty() {
        return "other";
    }
    use std::io::Read;
    let mut head = vec![0u8; 4096];
    let n = std::fs::File::open(path).and_then(|mut f| f.read(&mut head)).unwrap_or(0);
    head.truncate(n);
    if !head.contains(&0) && std::str::from_utf8(&head).is_ok() { "text" } else { "other" }
}

/// One folder for the phone: folders first, then files, by name. Hidden entries are left out.
pub fn listing(dir: &Path) -> Value {
    match home() {
        Some(home) => listing_in(dir, &home),
        None => json!({ "ok": false, "note": "No home folder." }),
    }
}

pub fn listing_in(dir: &Path, home: &Path) -> Value {
    let home = home.to_path_buf();
    let Ok(read) = std::fs::read_dir(dir) else {
        return json!({ "ok": false, "note": "Nyeko can't read this folder." });
    };
    let mut entries: Vec<(bool, String, Value)> = Vec::new();
    for item in read.flatten() {
        let name = item.file_name().to_string_lossy().to_string();
        if name.starts_with('.') || item.metadata().is_ok_and(|m| hidden(&m)) {
            continue;
        }
        let Ok(real) = std::fs::canonicalize(item.path()).map(|p| plain(&p)) else { continue };
        if !allowed(&real, &home) {
            continue;
        }
        let Ok(meta) = std::fs::metadata(&real) else { continue };
        let mut e = json!({ "name": name.chars().take(200).collect::<String>(), "dir": meta.is_dir() });
        if !meta.is_dir() {
            e["size"] = json!(meta.len());
            e["kind"] = json!(if mime(&real).is_some() { "image" } else if TEXT.contains(&ext(&real).as_str()) { "text" } else { "other" });
        }
        if let Some(t) = meta.modified().ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()) {
            e["mtime"] = json!(t.as_secs());
        }
        entries.push((meta.is_dir(), name.to_lowercase(), e));
    }
    entries.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
    let truncated = entries.len() > MAX_ENTRIES;
    let list: Vec<Value> = entries.into_iter().take(MAX_ENTRIES).map(|(_, _, e)| e).collect();
    let mut out = json!({ "ok": true, "path": dir.display().to_string(), "display": display(dir, &home), "entries": list, "truncated": truncated });
    if dir != home {
        if let Some(parent) = dir.parent() {
            out["parent"] = json!(parent.display().to_string());
        }
    }
    out
}

/// A file for the phone: the header, then its bytes in base64 chunks. Text is cut at MAX_TEXT; an image over MAX_BINARY
/// and any other kind aren't sent (the header says so).
pub fn preview(path: &Path) -> (Value, Vec<String>) {
    match home() {
        Some(home) => preview_in(path, &home),
        None => (json!({ "ok": false, "note": "No home folder." }), vec![]),
    }
}

pub fn preview_in(path: &Path, home: &Path) -> (Value, Vec<String>) {
    let home = home.to_path_buf();
    let Ok(meta) = std::fs::metadata(path) else { return (json!({ "ok": false, "note": "That file isn't there any more." }), vec![]) };
    if meta.is_dir() {
        return (json!({ "ok": false, "note": "That is a folder." }), vec![]);
    }
    let size = meta.len() as usize;
    let k = kind(path);
    let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    let mut header = json!({ "ok": true, "path": path.display().to_string(), "display": display(path, &home), "name": name, "size": size, "kind": k });
    if k == "other" || (k == "image" && size > MAX_BINARY) {
        header["chunks"] = json!(0);
        if k == "image" {
            header["note"] = json!("Too big to preview on the phone.");
        }
        return (header, vec![]);
    }
    let limit = if k == "text" { MAX_TEXT } else { MAX_BINARY };
    use std::io::Read;
    let mut data = Vec::new();
    if std::fs::File::open(path).and_then(|f| f.take(limit as u64).read_to_end(&mut data)).is_err() {
        return (json!({ "ok": false, "note": "Nyeko can't read this file." }), vec![]);
    }
    if k == "text" {
        // Cut on a whole character.
        while !data.is_empty() && std::str::from_utf8(&data).is_err() && size > data.len() {
            data.pop();
        }
        header["truncated"] = json!(size > data.len());
    } else {
        header["mime"] = json!(mime(path).unwrap_or("application/octet-stream"));
    }
    let chunks: Vec<String> = data.chunks(CHUNK).map(super::relay_crypto::base64url_encode).collect();
    header["chunks"] = json!(chunks.len());
    (header, chunks)
}

/// A folder a new session may start in: inside the home folder, not hidden, and really a folder.
pub fn launch_folder(asked: &str) -> Option<String> {
    let p = resolve(Some(asked))?;
    p.is_dir().then(|| p.display().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A home folder of the test's own (writing_backs_up_preserves… in hooks.rs points the real one elsewhere).
    fn fake_home(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("nyeko-files-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        plain(&std::fs::canonicalize(&dir).unwrap())
    }

    #[test]
    fn only_the_home_folder_and_nothing_hidden() {
        let home = fake_home("rules");
        std::fs::create_dir_all(home.join("Projects").join("app")).unwrap();
        std::fs::create_dir_all(home.join(".ssh")).unwrap();
        assert!(allowed(&home, &home));
        assert!(!allowed(&home.join(".ssh"), &home));
        assert!(!allowed(&home.join("Projects").join(".env"), &home));
        assert!(allowed(&home.join("Projects").join("app"), &home));
        assert!(!allowed(Path::new(if cfg!(windows) { r"C:\Windows" } else { "/etc" }), &home));
        assert_eq!(resolve_in(Some(""), &home), Some(home.clone()));
        assert_eq!(resolve_in(Some("~/Projects/app"), &home), Some(home.join("Projects").join("app")));
        assert_eq!(resolve_in(Some("relative/path"), &home), None);
        assert_eq!(resolve_in(Some(&home.join(".ssh").display().to_string()), &home), None);
        assert_eq!(resolve_in(Some(&home.join("Projects").join("..").join("..").display().to_string()), &home), None);
        std::fs::remove_dir_all(&home).unwrap();
    }

    #[test]
    fn a_folder_lists_folders_first_and_hides_dotfiles() {
        let home = fake_home("list");
        let dir = home.join("work");
        std::fs::create_dir_all(dir.join("b-folder")).unwrap();
        std::fs::write(dir.join("a.txt"), "héllo").unwrap();
        std::fs::write(dir.join(".secret"), "x").unwrap();
        let l = listing_in(&dir, &home);
        let names: Vec<&str> = l["entries"].as_array().unwrap().iter().map(|e| e["name"].as_str().unwrap()).collect();
        assert_eq!(names, ["b-folder", "a.txt"]);
        assert_eq!(l["parent"].as_str(), Some(home.display().to_string().as_str()));
        let (h, chunks) = preview_in(&dir.join("a.txt"), &home);
        assert_eq!((h["kind"].as_str(), h["chunks"].as_u64(), h["truncated"].as_bool()), (Some("text"), Some(1), Some(false)));
        assert_eq!(super::super::relay_crypto::base64url_decode(&chunks[0]).unwrap(), "héllo".as_bytes());
        assert!(resolve_in(Some(&dir.join(".secret").display().to_string()), &home).is_none());
        std::fs::remove_dir_all(&home).unwrap();
    }
}
