//! Core of the Smart Disk: everything the drive knows lives here.
//!
//! The core reads original files but never writes to them. Backends
//! (FUSE, the mirror folder, later FSKit) only render [`volume::SmartVolume`].

pub mod categories;
pub mod config;
pub mod db;
pub mod embed;
pub mod extract;
pub mod facts;
pub mod helper;
pub mod index;
pub mod query;
pub mod text;
pub mod views;
pub mod volume;
pub mod why;

pub use config::Config;
pub use db::Db;
