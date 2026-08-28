//! `cairn dev` — run cairn-server locally using `cairn.toml` + `.env`.

use std::path::{Path, PathBuf};
use std::process::Stdio;

use anyhow::{Context, Result};
use tokio::process::Command;

use crate::config::{CairnConfig, DEFAULT_FILE_NAME};
use crate::dotenv;

pub async fn run(cwd: &Path) -> Result<()> {
    let cfg = CairnConfig::load(&cwd.join(DEFAULT_FILE_NAME))?;

    let env_path = cwd.join(".env");
    let dotenv_vars = dotenv::read(&env_path);
    let pg_url = dotenv_vars.get(&cfg.db.url_env).cloned().with_context(|| {
        format!(
            "{} is not set in {} — run `cairn init` first",
            cfg.db.url_env,
            env_path.display()
        )
    })?;
    let jwt_secret = dotenv_vars
        .get("CAIRN_SUPABASE_JWT_SECRET")
        .map(String::as_str);
    let mut env_pairs = cfg.server_env(&pg_url, jwt_secret);
    push_rules_file_env(&mut env_pairs, cwd);
    push_crdt_columns_env(&mut env_pairs, &dotenv_vars);

    let binary = locate_server_binary();
    println!("Starting cairn-server ({})...", binary.describe());
    print_startup_banner(&cfg);

    let mut cmd = binary.command();
    for (k, v) in &env_pairs {
        cmd.env(k, v);
    }
    cmd.stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit());

    let mut child = cmd.spawn().context("spawning cairn-server")?;

    // Ctrl-C in a terminal is delivered to the whole foreground process
    // group — cairn-server's own SIGINT/SIGTERM handler
    // (`crates/cairn-server/src/main.rs::shutdown_signal`) will see it too
    // and drain gracefully. We just wait for it to actually exit so we don't
    // return (and let the terminal reclaim the prompt) before it's done.
    tokio::select! {
        () = ctrl_c_or_pending() => {
            println!("\nreceived Ctrl-C, waiting for cairn-server to shut down...");
        }
        status = child.wait() => {
            let status = status.context("waiting for cairn-server")?;
            anyhow::bail!("cairn-server exited unexpectedly: {status}");
        }
    }
    let status = child
        .wait()
        .await
        .context("waiting for cairn-server to exit")?;
    println!("cairn-server exited: {status}");
    Ok(())
}

/// `CairnConfig::server_env` knows nothing about the project directory, so
/// the `cairn_rules.toml` default on the server's `Config` resolves *by
/// coincidence* (the child inherits our cwd). Make the path explicit instead
/// of relying on that. Not folded into `server_env` itself — `deploy.rs`
/// conceptually shares that helper's shape, where the rules file ships
/// inside the image and the server's own relative default is correct.
fn push_rules_file_env(env_pairs: &mut Vec<(String, String)>, cwd: &Path) {
    env_pairs.push((
        "CAIRN_RULES_FILE".to_string(),
        cwd.join("cairn_rules.toml").display().to_string(),
    ));
}

/// Forward the CRDT column declarations from `.env` to the server child.
/// `cairn.toml` has no CRDT section — `CAIRN_COUNTER_COLUMNS` /
/// `CAIRN_OR_SET_COLUMNS` are operator env the SERVER parses directly
/// (cairn-infra write_back.rs), so `CairnConfig::server_env` rightly knows
/// nothing about them; but without this bridge a `cairn dev` launch silently
/// DROPPED them (the whitelist builds the child env from scratch), and CRDT
/// writes fell through to the clobber path. Empty values are not forwarded —
/// same rule as the JWT secret above.
fn push_crdt_columns_env(
    env_pairs: &mut Vec<(String, String)>,
    dotenv_vars: &std::collections::BTreeMap<String, String>,
) {
    for key in ["CAIRN_COUNTER_COLUMNS", "CAIRN_OR_SET_COLUMNS"] {
        if let Some(value) = dotenv_vars.get(key).filter(|v| !v.is_empty()) {
            env_pairs.push((key.to_string(), value.clone()));
        }
    }
}

async fn ctrl_c_or_pending() {
    if tokio::signal::ctrl_c().await.is_err() {
        std::future::pending::<()>().await;
    }
}

enum ServerBinary {
    /// A `cairn-server` binary co-installed next to this `cairn` binary
    /// (the release-artifact case, W6).
    Path(PathBuf),
    /// Dev fallback: build+run cairn-server from the workspace.
    ///
    /// ponytail: this always spawns a *child process*, whichever branch —
    /// there's no in-process embed. Upgrade path once distribution matters
    /// (W6): either vendor the cairn-server binary into the `cairn` release
    /// artifact (true single static binary), or give cairn-server a library
    /// entry point (`cairn_server::run(Config)`) this crate can call
    /// in-process, cutting the process-spawn + env-var handoff entirely.
    Cargo,
}

impl ServerBinary {
    fn describe(&self) -> String {
        match self {
            Self::Path(p) => p.display().to_string(),
            Self::Cargo => "cargo run -p cairn-server".to_string(),
        }
    }

    fn command(&self) -> Command {
        match self {
            Self::Path(p) => Command::new(p),
            Self::Cargo => {
                let mut c = Command::new("cargo");
                c.args([
                    "run",
                    "--quiet",
                    "-p",
                    "cairn-server",
                    "--features",
                    "pg",
                    "--",
                ]);
                c
            }
        }
    }
}

fn locate_server_binary() -> ServerBinary {
    let sibling_name = if cfg!(windows) {
        "cairn-server.exe"
    } else {
        "cairn-server"
    };
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let candidate = dir.join(sibling_name);
            if candidate.is_file() {
                return ServerBinary::Path(candidate);
            }
        }
    }
    ServerBinary::Cargo
}

fn print_startup_banner(cfg: &CairnConfig) {
    let host = if cfg.server.bind.starts_with("0.0.0.0") {
        "localhost"
    } else {
        cfg.server.bind.split(':').next().unwrap_or("localhost")
    };
    let port = cfg.server.bind.rsplit(':').next().unwrap_or("8800");
    let ws_url = format!("ws://{host}:{port}{}", cfg.server.ws_path);
    println!("  ws URL: {ws_url}");
    println!();
    println!("  Flutter snippet:");
    println!("    final cairn = await Cairn.connect(");
    println!("      url: '{ws_url}',");
    println!("      token: supabaseSession.accessToken,");
    println!("    );");
    println!();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dev_env_includes_absolute_rules_file_path() {
        let mut env_pairs = Vec::new();
        let cwd = Path::new("/some/project/dir");
        push_rules_file_env(&mut env_pairs, cwd);
        let (_k, v) = env_pairs
            .iter()
            .find(|(k, _)| k == "CAIRN_RULES_FILE")
            .expect("CAIRN_RULES_FILE present");
        assert_eq!(v, &cwd.join("cairn_rules.toml").display().to_string());
        assert!(Path::new(v).is_absolute());
    }

    #[test]
    fn dev_env_forwards_crdt_columns_from_dotenv() {
        let mut dotenv_vars = std::collections::BTreeMap::new();
        dotenv_vars.insert(
            "CAIRN_COUNTER_COLUMNS".to_string(),
            "counters:value".to_string(),
        );
        dotenv_vars.insert(
            "CAIRN_OR_SET_COLUMNS".to_string(),
            "sets:tags".to_string(),
        );
        let mut env_pairs = Vec::new();
        push_crdt_columns_env(&mut env_pairs, &dotenv_vars);
        assert_eq!(
            env_pairs,
            vec![
                (
                    "CAIRN_COUNTER_COLUMNS".to_string(),
                    "counters:value".to_string()
                ),
                ("CAIRN_OR_SET_COLUMNS".to_string(), "sets:tags".to_string()),
            ]
        );
    }

    #[test]
    fn dev_env_omits_absent_or_empty_crdt_columns() {
        let mut env_pairs = Vec::new();
        push_crdt_columns_env(&mut env_pairs, &std::collections::BTreeMap::new());
        assert!(env_pairs.is_empty());

        let mut dotenv_vars = std::collections::BTreeMap::new();
        dotenv_vars.insert("CAIRN_COUNTER_COLUMNS".to_string(), String::new());
        push_crdt_columns_env(&mut env_pairs, &dotenv_vars);
        assert!(env_pairs.is_empty());
    }
}
