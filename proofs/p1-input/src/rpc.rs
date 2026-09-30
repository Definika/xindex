//! The two nodes P1's input comes from: a beacon node's REST API and an execution node's JSON-RPC.

use serde_json::{json, Value};
use std::time::Duration;

pub struct Nodes {
    client: reqwest::blocking::Client,
    beacon: String,
    execution: String,
}

impl Nodes {
    pub fn new(beacon: &str, execution: &str) -> Nodes {
        let client = reqwest::blocking::Client::builder()
            .timeout(Duration::from_secs(120))
            .user_agent("xindex-p1-input")
            .build()
            .expect("an HTTP client");
        Nodes {
            client,
            beacon: beacon.trim_end_matches('/').into(),
            execution: execution.into(),
        }
    }

    /// A beacon API path's `data`, retried a few times: public nodes drop requests under load.
    pub fn beacon(&self, path: &str) -> Result<Value, String> {
        let url = format!("{}{}", self.beacon, path);
        let mut last = String::new();
        for attempt in 0..4 {
            if attempt > 0 {
                std::thread::sleep(Duration::from_secs(2 * attempt));
            }
            match self.client.get(&url).send() {
                Ok(r) if r.status().is_success() => {
                    let v: Value = r.json().map_err(|e| e.to_string())?;
                    return v
                        .get("data")
                        .cloned()
                        .ok_or_else(|| format!("{url}: no data"));
                }
                Ok(r) if r.status().as_u16() == 404 => return Err(format!("{url}: not found")),
                Ok(r) => last = format!("{url}: HTTP {}", r.status()),
                Err(e) => last = format!("{url}: {e}"),
            }
        }
        Err(last)
    }

    pub fn execution(&self, method: &str, params: Value) -> Result<Value, String> {
        let body = json!({"jsonrpc": "2.0", "id": 1, "method": method, "params": params});
        let mut last = String::new();
        for attempt in 0..4 {
            if attempt > 0 {
                std::thread::sleep(Duration::from_secs(2 * attempt));
            }
            match self.client.post(&self.execution).json(&body).send() {
                Ok(r) if r.status().is_success() => {
                    let v: Value = r.json().map_err(|e| e.to_string())?;
                    if let Some(result) = v.get("result") {
                        return Ok(result.clone());
                    }
                    last = format!("{method}: {}", v.get("error").cloned().unwrap_or_default());
                }
                Ok(r) => last = format!("{method}: HTTP {}", r.status()),
                Err(e) => last = format!("{method}: {e}"),
            }
        }
        Err(last)
    }
}

pub fn hex_bytes(v: &Value) -> Result<Vec<u8>, String> {
    let s = v.as_str().ok_or("not a string")?;
    hex::decode(s.trim_start_matches("0x")).map_err(|e| e.to_string())
}

pub fn hex_fixed<const N: usize>(v: &Value) -> Result<[u8; N], String> {
    hex_bytes(v)?
        .try_into()
        .map_err(|_| format!("not {N} bytes"))
}

/// A quantity: a decimal string (beacon API) or a hex string (JSON-RPC).
pub fn number(v: &Value) -> Result<u64, String> {
    let s = v.as_str().ok_or("not a string")?;
    match s.strip_prefix("0x") {
        Some(h) => u64::from_str_radix(h, 16).map_err(|e| e.to_string()),
        None => s
            .parse()
            .map_err(|e: std::num::ParseIntError| e.to_string()),
    }
}
