//! `cairn link` — app-side: scaffold `.cairn/` (config.json + gitignored
//! `local/`) at the app repo root. See ADR-0023 D1/D3. Distinct from the
//! operator `cairn init` (publication + `cairn.toml`).

use std::path::Path;

use anyhow::{bail, Result};
use clap::Args;

use crate::config::{Backend, ProjectConfig, DOT_CAIRN_DIR, LOCAL_DIR};
use crate::prompt::prompt_nonempty;

#[derive(Debug, Args)]
pub struct LinkArgs {
    /// The cairn-server `/sync` WebSocket URL (`ws://` or `wss://`). Prompted
    /// for if omitted.
    #[arg(long)]
    pub sync_url: Option<String>,
    /// Backend kind: `postgres` | `supabase` | `appwrite` (ADR-0023 D4).
    /// Defaults to `postgres` when omitted.
    #[arg(long)]
    pub backend: Option<String>,
    /// Supabase project URL (with `--backend supabase`).
    #[arg(long)]
    pub supabase_url: Option<String>,
    /// Supabase publishable (anon) key (with `--backend supabase`).
    #[arg(long)]
    pub supabase_anon_key: Option<String>,
    /// Human project name (informational).
    #[arg(long, default_value = "cairn-app")]
    pub project: String,
}

/// Run `cairn link`: resolve the sync URL + backend, write `.cairn/config.json`,
/// create the gitignored `.cairn/local/`, and ensure `.gitignore` covers it.
///
/// # Errors
/// [`anyhow::Error`] if the sync URL is not `ws://`/`wss://`, the backend kind
/// is unknown, a required (prompted) value is empty, or any disk write fails.
// `async` by contract: `main.rs` dispatches `run(args, &cwd).await` alongside
// the other subcommands, so the signature must stay async even though the link
// body is pure file IO today. ponytail: drop this allow if link grows a
// reachability probe against `sync_url` (the natural async surface).
#[allow(clippy::unused_async)]
pub async fn run(args: LinkArgs, cwd: &Path) -> Result<()> {
    let sync_url = match args.sync_url {
        Some(u) => u,
        None => prompt_nonempty("cairn-server /sync URL (ws:// or wss://): ")?,
    };
    if !(sync_url.starts_with("ws://") || sync_url.starts_with("wss://")) {
        bail!(
            "sync URL must start with `ws://` or `wss://` (got `{sync_url}`); \
             `cairn link` needs the cairn-server WebSocket endpoint"
        );
    }

    let backend = resolve_backend(
        args.backend.as_deref(),
        args.supabase_url.as_deref(),
        args.supabase_anon_key.as_deref(),
    )?;

    let config = ProjectConfig {
        project: args.project,
        sync_url,
        backend: Some(backend),
    };
    config.save(cwd)?;

    let local_dir = cwd.join(DOT_CAIRN_DIR).join(LOCAL_DIR);
    std::fs::create_dir_all(&local_dir)?;

    ensure_gitignore_local(cwd)?;

    println!("\u{2713} wrote `.cairn/config.json`");
    println!("\u{2713} created gitignored `.cairn/local/`");
    println!(
        "note: only publishable keys belong in config.json \u{2014} \
         service keys / JWT secrets / DB passwords go in `.env` or `.cairn/local/`"
    );
    println!("next: `cairn pull && cairn gen`");
    Ok(())
}

fn resolve_backend(
    kind: Option<&str>,
    supabase_url: Option<&str>,
    supabase_anon_key: Option<&str>,
) -> Result<Backend> {
    match kind.unwrap_or("postgres") {
        "postgres" => Ok(Backend::Postgres),
        "supabase" => {
            let url = match supabase_url {
                Some(u) => u.to_string(),
                None => prompt_nonempty("Supabase project URL (https://...supabase.co): ")?,
            };
            let anon_key = match supabase_anon_key {
                Some(k) => k.to_string(),
                None => prompt_nonempty("Supabase publishable (anon) key: ")?,
            };
            Ok(Backend::Supabase { url, anon_key })
        }
        "appwrite" => bail!("appwrite backend is post-v1 (ADR-0023 D4)"),
        other => {
            bail!("unknown backend `{other}`; valid options: `postgres`, `supabase`, `appwrite`")
        }
    }
}

fn ensure_gitignore_local(cwd: &Path) -> Result<()> {
    const ENTRY: &str = ".cairn/local/";
    let path = cwd.join(".gitignore");
    let existing = std::fs::read_to_string(&path).unwrap_or_default();
    if existing.lines().any(|line| line.trim() == ENTRY) {
        return Ok(());
    }
    let mut content = existing;
    if !content.is_empty() && !content.ends_with('\n') {
        content.push('\n');
    }
    content.push_str(ENTRY);
    content.push('\n');
    std::fs::write(&path, content)?;
    Ok(())
}
