//! Bridge to `slim-helper`, a small Swift tool that wraps Apple frameworks:
//! PDFKit for PDFs, Vision for OCR, and Foundation Models for folder names.

use anyhow::{anyhow, bail, Context, Result};
use serde::Deserialize;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

#[derive(Debug, Clone)]
pub struct Helper {
    pub path: PathBuf,
}

#[derive(Debug, Deserialize)]
pub struct Extracted {
    pub text: String,
    /// "pdfkit", "vision-ocr", "pdfkit+ocr", "attributed-string"…
    pub method: String,
}

#[derive(Debug, Default, Deserialize)]
pub struct Capabilities {
    pub ocr: bool,
    pub foundation_models: bool,
    #[serde(default)]
    pub foundation_models_reason: Option<String>,
}

impl Helper {
    /// Finds the helper: explicit path, `SLIM_HELPER`, next to this binary,
    /// inside an app bundle, or the Swift build folder of a source checkout.
    pub fn locate(explicit: Option<&Path>) -> Option<Helper> {
        let mut candidates: Vec<PathBuf> = Vec::new();
        if let Some(p) = explicit {
            candidates.push(p.to_path_buf());
        }
        if let Some(p) = std::env::var_os("SLIM_HELPER") {
            candidates.push(PathBuf::from(p));
        }
        if let Ok(exe) = std::env::current_exe() {
            let exe = exe.canonicalize().unwrap_or(exe);
            if let Some(dir) = exe.parent() {
                candidates.push(dir.join("slim-helper"));
                // target/{debug,release}/slim -> macos/.build/release/slim-helper
                if let Some(repo) = dir.parent().and_then(Path::parent) {
                    candidates.push(repo.join("macos/.build/release/slim-helper"));
                    candidates.push(repo.join("macos/.build/debug/slim-helper"));
                }
            }
        }
        candidates.push(PathBuf::from("/Applications/SmartDisk.app/Contents/MacOS/slim-helper"));
        candidates.push(PathBuf::from("/opt/homebrew/bin/slim-helper"));
        candidates.push(PathBuf::from("/usr/local/bin/slim-helper"));
        candidates.into_iter().find(|p| p.is_file()).map(|path| Helper { path })
    }

    fn run(&self, args: &[&str], timeout: Duration) -> Result<Vec<u8>> {
        let mut child = Command::new(&self.path)
            .args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .with_context(|| format!("starting {}", self.path.display()))?;
        let mut stdout = child.stdout.take().unwrap();
        let reader = std::thread::spawn(move || {
            let mut buf = Vec::new();
            let _ = stdout.read_to_end(&mut buf);
            buf
        });
        let start = Instant::now();
        let status = loop {
            if let Some(status) = child.try_wait()? {
                break status;
            }
            if start.elapsed() > timeout {
                let _ = child.kill();
                let _ = child.wait();
                bail!("slim-helper timed out after {}s", timeout.as_secs());
            }
            std::thread::sleep(Duration::from_millis(20));
        };
        let out = reader.join().map_err(|_| anyhow!("reader thread panicked"))?;
        if !status.success() {
            let mut err = String::new();
            if let Some(mut e) = child.stderr.take() {
                let _ = e.read_to_string(&mut err);
            }
            bail!("slim-helper failed: {}", err.trim());
        }
        Ok(out)
    }

    pub fn extract(&self, path: &Path) -> Result<Extracted> {
        let out = self.run(&["extract", &path.to_string_lossy()], Duration::from_secs(120))?;
        Ok(serde_json::from_slice(&out)?)
    }

    pub fn capabilities(&self) -> Result<Capabilities> {
        let out = self.run(&["capabilities"], Duration::from_secs(10))?;
        Ok(serde_json::from_slice(&out)?)
    }

    /// Asks Apple's on-device model to read a folder name. Returns raw JSON.
    pub fn parse_query(&self, name: &str) -> Result<serde_json::Value> {
        let out = self.run(&["parse-query", name], Duration::from_secs(30))?;
        Ok(serde_json::from_slice(&out)?)
    }
}
