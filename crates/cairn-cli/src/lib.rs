//! Library surface for the `cairn` binary (`src/main.rs`) — split out so
//! `tests/` integration tests (notably the `CAIRN_E2E_PG=1`-gated real-
//! Postgres suite) can exercise `pg::PgControl` and `config::CairnConfig`
//! directly instead of shelling out to the built binary.

pub mod commands;
pub mod config;
pub mod dotenv;
pub mod pg;
pub mod prompt;
