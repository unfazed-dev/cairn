//! `cairn` — the CLI for a Postgres + Supabase Cairn backend: `init` sets up
//! the publication and writes `cairn.toml`/`.env`, `dev` runs the sync
//! server locally, `doctor` reports health, `deploy` generates self-host
//! config. See `docs/plans/flutter-supabase-plug-and-play-launch.md` (W3).

use anyhow::{Context, Result};
use cairn_cli::commands;
use clap::{Parser, Subcommand};

#[derive(Debug, Parser)]
#[command(
    name = "cairn",
    version,
    about = "Cairn — a local-first sync backend for Postgres + Supabase"
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Debug, Subcommand)]
enum Commands {
    /// Connect to Postgres, create/update the publication, write cairn.toml + .env.
    Init(commands::init::InitArgs),
    /// Run cairn-server locally using cairn.toml + .env.
    Dev,
    /// Connectivity, replication health, and JWKS reachability checks.
    Doctor,
    /// Generate a self-host deploy config (fly/railway) from cairn.toml.
    Deploy(commands::deploy::DeployArgs),
    /// App-side: scaffold `.cairn/` (config.json + gitignored local/).
    Link(commands::link::LinkArgs),
    /// App-side: fetch GET /schema → `.cairn/schema.json`.
    Pull(commands::pull::PullArgs),
    /// App-side: generate per-SDK source from `.cairn/`.
    Gen(commands::gen::GenArgs),
    /// Generate/edit/validate cairn_rules.toml (per-table sync rules, ADR-0031).
    Rules(commands::rules::RulesArgs),
}

#[tokio::main]
async fn main() -> Result<()> {
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info"));
    let _ = tracing_subscriber::fmt().with_env_filter(filter).try_init();

    let cli = Cli::parse();
    let cwd = std::env::current_dir().context("reading current directory")?;

    match cli.command {
        Commands::Init(args) => commands::init::run(args, &cwd).await,
        Commands::Dev => commands::dev::run(&cwd).await,
        Commands::Doctor => commands::doctor::run(&cwd).await,
        Commands::Deploy(args) => commands::deploy::run(args, &cwd),
        Commands::Link(args) => commands::link::run(args, &cwd).await,
        Commands::Pull(args) => commands::pull::run(args, &cwd).await,
        Commands::Gen(args) => commands::gen::run(args, &cwd).await,
        Commands::Rules(args) => commands::rules::run(args, &cwd).await,
    }
}
