//! Backends that show the Smart Disk to Finder, open/save panels and the terminal.
//!
//! - [`mirror`]: a folder of symbolic links, no install required.
//! - `fuse` (feature `fuse`): a real drive via macFUSE or FUSE-T.
//!
//! Both render the same [`slim_core::volume::VirtualVolume`]; a native FSKit
//! extension is the planned third backend.

pub mod mirror;

#[cfg(feature = "fuse")]
pub mod fuse;

/// True when this build can mount a real FUSE drive.
pub const FUSE_AVAILABLE: bool = cfg!(feature = "fuse");
