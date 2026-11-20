//! Nyeko: setting this computer up from a phone that already knows the relay (docs/RELAY_SETUP.md).
//!
//! While no relay is set, Settings → Phone shows a QR code: the relay's address, a one-time setup room and a P-256 public
//! key. The phone (web app, phone/web/setup.js) scans it, meets this computer in that setup room (the relay opens setup
//! rooms without the access key, for a few small frames) and sends the relay's address and access key, encrypted to this
//! computer's key. They are saved like the fields in Settings, the phone link is turned on, and the answer is this
//! computer's pairing code, which the phone adds like any other. Nothing is typed here.
//!
//! The same protocol as the Mac (NyekoSetup.swift) and the web app's `offerSetup`:
//!   join proof  b64url(SHA-256("nyeko-setup/v1 join <room> <pub>"))
//!   key         HKDF-SHA256(ECDH-P256 x, salt = room, info = "nyeko-setup/v1", 32)
//!   phone → pc  0x01 ‖ phone public key (65) ‖ nonce (12) ‖ AES-256-GCM({relay, access, phone}), aad "nyeko-setup/v1 hello <room>"
//!   pc → phone  0x02 ‖ nonce (12) ‖ AES-256-GCM({code, name} | {error}), aad "nyeko-setup/v1 done <room>"

use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use ring::aead::{self, Aad, LessSafeKey, Nonce, UnboundKey};
use ring::agreement::{self, EphemeralPrivateKey, UnparsedPublicKey};
use ring::digest;
use ring::rand::SystemRandom;
use serde::Serialize;
use serde_json::{json, Value};
use tokio_tungstenite::tungstenite::Message;

use super::relay_client::{self, Target};
use super::relay_crypto as crypto;

pub const SETUP: &str = "nyeko-setup/v1";
const HELLO: u8 = 1;
const DONE: u8 = 2;
/// The relay keeps a setup room 15 minutes; the code is replaced a little before.
const TTL: Duration = Duration::from_secs(14 * 60);
/// The relay answers a text "ping" itself; it keeps the socket alive while the code is on screen.
const PING: Duration = Duration::from_secs(30);
/// The relay's own limit for a setup frame.
const MAX_FRAME: usize = 4096;

/// What Settings shows. `reason` names why it failed (the window words it): unreachable, expired, other, error (then
/// `message` says what the computer could not do).
#[derive(Clone, Debug, Default, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SetupStatus {
    /// idle, waiting, done or failed.
    pub state: String,
    pub link: String,
    pub qr_svg: String,
    pub reason: String,
    pub message: String,
    /// The phone that set this computer up (done).
    pub phone: String,
}

impl SetupStatus {
    pub fn idle() -> Self {
        SetupStatus { state: "idle".into(), ..Default::default() }
    }
    fn failed(&mut self, reason: &str, message: &str) {
        self.state = "failed".into();
        self.reason = reason.into();
        self.message = message.into();
    }
}

/// Saves the relay's address and access key, turns the link on, and returns (pairing code, this computer's name), or a
/// sentence for the phone. Runs on a plain thread: it may start the link, which blocks on the async runtime.
pub type Apply = Arc<dyn Fn(&str, &str) -> Result<(String, String), String> + Send + Sync>;

/// One code on screen: what goes in the QR, and the private key only this computer holds.
pub struct Offer {
    pub link: String,
    room: String,
    pub_b64: String,
    private: EphemeralPrivateKey,
}

/// A new offer for `relay`, as the link `<site>/#setup=…` the phone's camera opens.
pub fn new_offer(site: &str, relay: &Target, name: &str, cid: &str) -> Result<Offer, String> {
    let rng = SystemRandom::new();
    let private = EphemeralPrivateKey::generate(&agreement::ECDH_P256, &rng).map_err(|_| "no secure random source".to_string())?;
    let public = private.compute_public_key().map_err(|_| "no secure random source".to_string())?;
    let pub_b64 = crypto::base64url_encode(public.as_ref());
    let room = crypto::base64url_encode(&relay_client::random_bytes::<16>()?);
    let code = json!({ "v": 1, "relay": relay.display(), "room": room, "pub": pub_b64, "name": name, "cid": cid });
    let link = format!("{}/#setup={}", site.trim_end_matches('/'), crypto::base64url_encode(code.to_string().as_bytes()));
    Ok(Offer { link, room, pub_b64, private })
}

pub fn join_proof(room: &str, pub_b64: &str) -> String {
    crypto::base64url_encode(digest::digest(&digest::SHA256, format!("{SETUP} join {room} {pub_b64}").as_bytes()).as_ref())
}

fn aes_key(private: EphemeralPrivateKey, peer: &[u8], room: &str) -> Option<LessSafeKey> {
    let mut key = [0u8; 32];
    agreement::agree_ephemeral(private, &UnparsedPublicKey::new(&agreement::ECDH_P256, peer), |shared| {
        crypto::hkdf_sha256(shared, room.as_bytes(), SETUP.as_bytes(), &mut key)
    })
    .ok()?;
    let unbound = UnboundKey::new(&aead::AES_256_GCM, &key).ok();
    key.fill(0);
    Some(LessSafeKey::new(unbound?))
}

fn open(key: &LessSafeKey, aad: &str, sealed: &[u8]) -> Option<Value> {
    if sealed.len() < 12 + 16 {
        return None;
    }
    let nonce = Nonce::try_assume_unique_for_key(&sealed[..12]).ok()?;
    let mut buf = sealed[12..].to_vec();
    let plain = key.open_in_place(nonce, Aad::from(aad.as_bytes()), &mut buf).ok()?;
    let value = serde_json::from_slice(plain).ok();
    buf.fill(0);
    value
}

fn seal(key: &LessSafeKey, aad: &str, value: &Value) -> Result<Vec<u8>, String> {
    let n = relay_client::random_bytes::<12>()?;
    let mut buf = value.to_string().into_bytes();
    key.seal_in_place_append_tag(Nonce::assume_unique_for_key(n), Aad::from(aad.as_bytes()), &mut buf)
        .map_err(|_| "could not encrypt".to_string())?;
    let mut frame = Vec::with_capacity(1 + 12 + buf.len());
    frame.push(DONE);
    frame.extend_from_slice(&n);
    frame.extend_from_slice(&buf);
    Ok(frame)
}

/// Waits in the setup room until a phone sends the relay, then applies it and answers. Updates `status` as it goes; ends on
/// success, failure or after the TTL.
pub async fn run(offer: Offer, target: Target, apply: Apply, status: Arc<Mutex<SetupStatus>>) {
    let fail = |reason: &str, message: &str| status.lock().unwrap().failed(reason, message);
    let Offer { room, pub_b64, private, .. } = offer;
    let path = format!("/v1/setup/{room}?role=pc");
    let protocols = format!("coucou.v1, coucou.join.{}", join_proof(&room, &pub_b64));
    let Ok(ws) = relay_client::open_socket(&target, &path, None, &protocols, MAX_FRAME + 1024).await else {
        return fail("unreachable", "");
    };
    let (mut tx, mut rx) = ws.split();
    let deadline = tokio::time::Instant::now() + TTL;
    let mut ping = tokio::time::interval(PING);
    ping.tick().await;
    let mut private = Some(private);
    loop {
        tokio::select! {
            _ = tokio::time::sleep_until(deadline) => return fail("expired", ""),
            _ = ping.tick() => {
                if tx.send(Message::Text("ping".into())).await.is_err() {
                    return fail("expired", "");
                }
            }
            msg = rx.next() => {
                let frame = match msg {
                    Some(Ok(Message::Binary(b))) => b,
                    Some(Ok(_)) => continue, // {"peer":…} notices, pongs
                    _ => return fail("expired", ""),
                };
                if frame.len() < 1 + 65 + 12 + 16 || frame[0] != HELLO {
                    continue;
                }
                // The private key is single-use (ring): a frame that does not open ends this code.
                let Some(mine) = private.take() else { continue };
                let hello = aes_key(mine, &frame[1..66], &room)
                    .and_then(|key| open(&key, &format!("{SETUP} hello {room}"), &frame[66..]).map(|h| (key, h)));
                let Some((key, hello)) = hello else { return fail("other", "") };
                let relay = hello["relay"].as_str().unwrap_or_default().to_string();
                let access = hello["access"].as_str().unwrap_or_default().to_string();
                let phone: String = hello["phone"].as_str().unwrap_or("Phone").chars().take(64).collect();
                let (done_tx, done_rx) = tokio::sync::oneshot::channel();
                std::thread::spawn(move || {
                    let _ = done_tx.send(apply(&relay, &access));
                });
                let result = done_rx.await.unwrap_or_else(|_| Err("This computer could not save the settings.".into()));
                let reply = match &result {
                    Ok((code, name)) => json!({ "code": code, "name": name }),
                    Err(e) => json!({ "error": e }),
                };
                if let Ok(frame) = seal(&key, &format!("{SETUP} done {room}"), &reply) {
                    let _ = tx.send(Message::Binary(frame.into())).await;
                }
                let _ = tx.close().await;
                let mut s = status.lock().unwrap();
                match result {
                    Ok(_) => {
                        s.state = "done".into();
                        s.phone = phone;
                    }
                    Err(e) => s.failed("error", &e),
                }
                return;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_offer_link_carries_what_the_phone_checks() {
        let target = Target::parse("wss://relay.example.workers.dev").unwrap();
        let offer = new_offer("https://nyeko-phone.pages.dev/", &target, "Test PC", "cid1").unwrap();
        let b64 = offer.link.strip_prefix("https://nyeko-phone.pages.dev/#setup=").unwrap();
        let j: Value = serde_json::from_slice(&crypto::base64url_decode(b64).unwrap()).unwrap();
        assert_eq!(j["v"], 1);
        assert_eq!(j["relay"], "wss://relay.example.workers.dev");
        assert_eq!(j["room"].as_str().unwrap().len(), 22);
        assert_eq!(j["pub"].as_str().unwrap().len(), 87);
        assert_eq!(j["name"], "Test PC");
        assert_eq!(join_proof(&offer.room, &offer.pub_b64).len(), 43);
    }

    #[test]
    fn a_hello_sealed_by_the_phone_opens_and_the_answer_seals() {
        let target = Target::parse("wss://relay.example.workers.dev").unwrap();
        let offer = new_offer("https://x.dev", &target, "PC", "").unwrap();
        let room = offer.room.clone();
        let pc_pub = crypto::base64url_decode(&offer.pub_b64).unwrap();
        // The phone's side.
        let rng = SystemRandom::new();
        let phone = EphemeralPrivateKey::generate(&agreement::ECDH_P256, &rng).unwrap();
        let phone_pub = phone.compute_public_key().unwrap().as_ref().to_vec();
        let phone_key = aes_key(phone, &pc_pub, &room).unwrap();
        let mut hello = seal(&phone_key, &format!("{SETUP} hello {room}"), &json!({ "relay": "wss://r.dev", "access": "a".repeat(20) })).unwrap();
        hello[0] = HELLO;
        // The computer's side.
        let pc_key = aes_key(offer.private, &phone_pub, &room).unwrap();
        let got = open(&pc_key, &format!("{SETUP} hello {room}"), &hello[1..]).unwrap();
        assert_eq!(got["relay"], "wss://r.dev");
        assert!(open(&pc_key, &format!("{SETUP} hello other"), &hello[1..]).is_none());
    }

    /// End to end with the web app's own phone side (phone/tests/setup-windows.mjs) over the relay's Node twin. Run by hand:
    ///   cargo test -p coucou --lib setup_with_the_web_app -- --ignored --nocapture
    #[test]
    #[ignore]
    fn setup_with_the_web_app_through_the_dev_relay() {
        use std::io::{BufRead, BufReader, Write};
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        let mut node = std::process::Command::new("node")
            .args(["--experimental-strip-types", "--no-warnings", "phone/tests/setup-windows.mjs"])
            .current_dir(&root)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .expect("node runs");
        let mut out = BufReader::new(node.stdout.take().unwrap());
        let mut line = String::new();
        out.read_line(&mut line).unwrap();
        let port: u16 = line.trim().strip_prefix("PORT ").expect("the relay starts").parse().unwrap();
        let target = Target { tls: false, host: "127.0.0.1".into(), port };
        let offer = new_offer("https://nyeko-phone.pages.dev", &target, "Test PC", "cid1").unwrap();
        let link = offer.link.clone();
        let saved = Arc::new(Mutex::new(None));
        let seen = saved.clone();
        let apply: Apply = Arc::new(move |relay, access| {
            *seen.lock().unwrap() = Some((relay.to_string(), access.to_string()));
            Ok(("https://nyeko-phone.pages.dev/#pair=WINDOWS".into(), "Test PC".into()))
        });
        let status = Arc::new(Mutex::new(SetupStatus { state: "waiting".into(), ..Default::default() }));
        let rt = tokio::runtime::Builder::new_multi_thread().enable_all().build().unwrap();
        let task = rt.spawn(run(offer, target, apply, status.clone()));
        std::thread::sleep(Duration::from_millis(500));
        writeln!(node.stdin.as_mut().unwrap(), "{link}").unwrap();
        line.clear();
        out.read_line(&mut line).unwrap();
        assert_eq!(line.trim(), "CODE https://nyeko-phone.pages.dev/#pair=WINDOWS");
        rt.block_on(task).unwrap();
        let s = status.lock().unwrap().clone();
        assert_eq!((s.state.as_str(), s.phone.as_str()), ("done", "Test iPhone"));
        assert_eq!(saved.lock().unwrap().clone(), Some(("wss://my-relay.example.workers.dev".into(), "B".repeat(43))));
        let _ = node.wait();
    }
}
