//! Discord local RPC: framed JSON over a Unix socket / Windows named pipe.

use serde_json::{Value, json};
use std::io::{Read, Write};

const OP_HANDSHAKE: u32 = 0;
const OP_FRAME: u32 = 1;
const OP_CLOSE: u32 = 2;

#[cfg(unix)]
type Stream = std::os::unix::net::UnixStream;
#[cfg(windows)]
type Stream = std::fs::File;

pub struct Ipc {
    client_id: String,
    stream: Option<Stream>,
}

fn candidates() -> Vec<String> {
    if cfg!(windows) {
        return (0..10).map(|i| format!(r"\\.\pipe\discord-ipc-{i}")).collect();
    }
    let mut bases: Vec<String> = ["XDG_RUNTIME_DIR", "TMPDIR", "TMP", "TEMP"].iter().filter_map(|v| std::env::var(v).ok()).collect();
    bases.push("/tmp".into());
    let mut out = Vec::new();
    for b in bases {
        for sub in ["", "app/com.discordapp.Discord", "snap.discord"] {
            let dir = if sub.is_empty() { b.clone() } else { format!("{b}/{sub}") };
            for i in 0..10 {
                out.push(format!("{dir}/discord-ipc-{i}"));
            }
        }
    }
    out
}

impl Ipc {
    pub fn new(client_id: &str) -> Self {
        Self { client_id: client_id.to_string(), stream: None }
    }

    pub fn connected(&self) -> bool {
        self.stream.is_some()
    }

    pub fn connect(&mut self) -> Result<(), String> {
        for p in candidates() {
            #[cfg(unix)]
            let s = Stream::connect(&p);
            #[cfg(windows)]
            let s = std::fs::OpenOptions::new().read(true).write(true).open(&p);
            if let Ok(s) = s {
                self.stream = Some(s);
                match self.handshake() {
                    Ok(()) => {
                        crate::log(&format!("Connected to Discord IPC at {p}"));
                        return Ok(());
                    }
                    Err(_) => self.stream = None,
                }
            }
        }
        Err("No Discord IPC socket found (is Discord running?)".into())
    }

    fn send(&mut self, op: u32, payload: &Value) -> Result<(), String> {
        let s = self.stream.as_mut().ok_or("not connected")?;
        let body = payload.to_string().into_bytes();
        let mut frame = Vec::with_capacity(8 + body.len());
        frame.extend_from_slice(&op.to_le_bytes());
        frame.extend_from_slice(&(body.len() as u32).to_le_bytes());
        frame.extend_from_slice(&body);
        s.write_all(&frame).map_err(|e| e.to_string())
    }

    fn recv(&mut self) -> Result<(u32, Value), String> {
        let s = self.stream.as_mut().ok_or("not connected")?;
        let mut h = [0u8; 8];
        s.read_exact(&mut h).map_err(|e| e.to_string())?;
        let op = u32::from_le_bytes([h[0], h[1], h[2], h[3]]);
        let len = u32::from_le_bytes([h[4], h[5], h[6], h[7]]) as usize;
        let mut b = vec![0u8; len];
        s.read_exact(&mut b).map_err(|e| e.to_string())?;
        Ok((op, serde_json::from_slice(&b).unwrap_or(Value::Null)))
    }

    fn handshake(&mut self) -> Result<(), String> {
        self.send(OP_HANDSHAKE, &json!({"v": 1, "client_id": self.client_id}))?;
        let (_, v) = self.recv()?;
        if v["evt"] != "READY" {
            return Err(format!("unexpected handshake response: {v}"));
        }
        Ok(())
    }

    pub fn set_activity(&mut self, activity: Option<Value>) -> Result<(), String> {
        let msg = json!({"cmd": "SET_ACTIVITY", "args": {"pid": std::process::id(), "activity": activity}, "nonce": uuid::Uuid::new_v4().to_string()});
        self.send(OP_FRAME, &msg)?;
        self.recv().map(|_| ())
    }

    pub fn close(&mut self) {
        if self.stream.is_some() {
            let _ = self.send(OP_CLOSE, &json!({}));
        }
        self.stream = None;
    }
}
