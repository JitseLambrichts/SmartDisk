//! FUSE backend (macFUSE or FUSE-T): the real virtual drive at /Volumes/Slim.
//!
//! A thin translation layer: inodes ↔ drive paths, everything else is
//! delegated to [`VirtualVolume`]. Files are read straight from the originals.

use fuser::{
    FileAttr, FileType, Filesystem, MountOption, ReplyAttr, ReplyData, ReplyDirectory, ReplyEmpty, ReplyEntry, ReplyOpen,
    ReplyStatfs, Request,
};
use slim_core::volume::{Node, SmartVolume, VirtualVolume, VolumeError};
use std::collections::HashMap;
use std::ffi::OsStr;
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// Short TTL: folder contents change behind the kernel's back all the time.
const TTL: Duration = Duration::from_secs(1);
const ROOT: u64 = 1;

pub struct SlimFs {
    volume: Arc<SmartVolume>,
    paths: Vec<String>,
    inodes: HashMap<String, u64>,
    uid: u32,
    gid: u32,
}

fn errno(e: &VolumeError) -> i32 {
    match e {
        VolumeError::NotFound => libc::ENOENT,
        VolumeError::NotPermitted(_) => libc::EPERM,
        VolumeError::Exists => libc::EEXIST,
        VolumeError::Other(_) => libc::EIO,
    }
}

fn join(parent: &str, name: &OsStr) -> String {
    let name = name.to_string_lossy();
    if parent == "/" { format!("/{name}") } else { format!("{parent}/{name}") }
}

impl SlimFs {
    pub fn new(volume: Arc<SmartVolume>) -> Self {
        let mut fs = SlimFs {
            volume,
            paths: vec![String::new()],
            inodes: HashMap::new(),
            uid: unsafe { libc::getuid() },
            gid: unsafe { libc::getgid() },
        };
        fs.ino("/");
        fs
    }

    fn ino(&mut self, path: &str) -> u64 {
        if let Some(i) = self.inodes.get(path) {
            return *i;
        }
        let i = self.paths.len() as u64;
        self.paths.push(path.to_owned());
        self.inodes.insert(path.to_owned(), i);
        i
    }

    fn path(&self, ino: u64) -> Option<String> {
        self.paths.get(ino as usize).filter(|p| !p.is_empty()).cloned()
    }

    fn attr(&self, ino: u64, node: &Node) -> FileAttr {
        let (kind, size, mtime, perm) = match node {
            Node::Root | Node::MetaDir | Node::Dir(_) => (FileType::Directory, 0, SystemTime::now(), 0o700),
            Node::File(f) => (FileType::RegularFile, f.size, UNIX_EPOCH + Duration::from_secs(f.mtime.max(0) as u64), 0o400),
            Node::MetaFile(_, b) => (FileType::RegularFile, b.len() as u64, SystemTime::now(), 0o400),
        };
        FileAttr {
            ino,
            size,
            blocks: size.div_ceil(512),
            atime: mtime,
            mtime,
            ctime: mtime,
            crtime: mtime,
            kind,
            perm,
            nlink: if kind == FileType::Directory { 2 } else { 1 },
            // Only the logged-in user may read the drive.
            uid: self.uid,
            gid: self.gid,
            rdev: 0,
            blksize: 4096,
            flags: 0,
        }
    }

    fn node_name(node: &Node) -> String {
        match node {
            Node::Root => String::new(),
            Node::MetaDir => slim_core::volume::META_DIR.to_owned(),
            Node::Dir(d) => d.name.clone(),
            Node::File(f) => f.name.clone(),
            Node::MetaFile(n, _) => n.clone(),
        }
    }
}

impl Filesystem for SlimFs {
    fn lookup(&mut self, _req: &Request, parent: u64, name: &OsStr, reply: ReplyEntry) {
        let Some(parent) = self.path(parent) else { return reply.error(libc::ENOENT) };
        let path = join(&parent, name);
        match self.volume.lookup(&path) {
            Ok(node) => {
                let ino = self.ino(&path);
                reply.entry(&TTL, &self.attr(ino, &node), 0)
            }
            Err(e) => reply.error(errno(&e)),
        }
    }

    fn getattr(&mut self, _req: &Request, ino: u64, _fh: Option<u64>, reply: ReplyAttr) {
        let Some(path) = self.path(ino) else { return reply.error(libc::ENOENT) };
        match self.volume.lookup(&path) {
            Ok(node) => reply.attr(&TTL, &self.attr(ino, &node)),
            Err(e) => reply.error(errno(&e)),
        }
    }

    fn readdir(&mut self, _req: &Request, ino: u64, _fh: u64, offset: i64, mut reply: ReplyDirectory) {
        let Some(path) = self.path(ino) else { return reply.error(libc::ENOENT) };
        let nodes = match self.volume.readdir(&path) {
            Ok(n) => n,
            Err(e) => return reply.error(errno(&e)),
        };
        let mut entries = vec![(ino, FileType::Directory, ".".to_owned()), (ROOT, FileType::Directory, "..".to_owned())];
        for n in nodes {
            let name = Self::node_name(&n);
            let child = self.ino(&join(&path, OsStr::new(&name)));
            let kind = match n {
                Node::File(_) | Node::MetaFile(..) => FileType::RegularFile,
                _ => FileType::Directory,
            };
            entries.push((child, kind, name));
        }
        for (i, (ino, kind, name)) in entries.into_iter().enumerate().skip(offset as usize) {
            if reply.add(ino, (i + 1) as i64, kind, name) {
                break;
            }
        }
        reply.ok()
    }

    fn open(&mut self, _req: &Request, ino: u64, flags: i32, reply: ReplyOpen) {
        // Read-only until writing is tested with Preview, Pages, Word and VS Code.
        if flags & libc::O_ACCMODE != libc::O_RDONLY {
            return reply.error(libc::EROFS);
        }
        match self.path(ino) {
            Some(_) => reply.opened(0, 0),
            None => reply.error(libc::ENOENT),
        }
    }

    fn read(&mut self, _req: &Request, ino: u64, _fh: u64, offset: i64, size: u32, _flags: i32, _lock: Option<u64>, reply: ReplyData) {
        let Some(path) = self.path(ino) else { return reply.error(libc::ENOENT) };
        match self.volume.read(&path, offset.max(0) as u64, size) {
            Ok(bytes) => reply.data(&bytes),
            Err(e) => reply.error(errno(&e)),
        }
    }

    fn mkdir(&mut self, _req: &Request, parent: u64, name: &OsStr, _mode: u32, _umask: u32, reply: ReplyEntry) {
        let Some(parent) = self.path(parent) else { return reply.error(libc::ENOENT) };
        let path = join(&parent, name);
        if let Err(e) = self.volume.mkdir(&path) {
            return reply.error(errno(&e));
        }
        match self.volume.lookup(&path) {
            Ok(node) => {
                let ino = self.ino(&path);
                reply.entry(&TTL, &self.attr(ino, &node), 0)
            }
            Err(e) => reply.error(errno(&e)),
        }
    }

    fn rmdir(&mut self, _req: &Request, parent: u64, name: &OsStr, reply: ReplyEmpty) {
        let Some(parent) = self.path(parent) else { return reply.error(libc::ENOENT) };
        match self.volume.rmdir(&join(&parent, name)) {
            Ok(()) => reply.ok(),
            Err(e) => reply.error(errno(&e)),
        }
    }

    fn unlink(&mut self, _req: &Request, parent: u64, name: &OsStr, reply: ReplyEmpty) {
        let Some(parent) = self.path(parent) else { return reply.error(libc::ENOENT) };
        // Finder litters .DS_Store files; pretend they are gone.
        if name == ".DS_Store" {
            return reply.ok();
        }
        match self.volume.unlink(&join(&parent, name)) {
            Ok(()) => reply.ok(),
            Err(e) => reply.error(errno(&e)),
        }
    }

    fn rename(&mut self, _req: &Request, parent: u64, name: &OsStr, newparent: u64, newname: &OsStr, _flags: u32, reply: ReplyEmpty) {
        let (Some(p), Some(np)) = (self.path(parent), self.path(newparent)) else { return reply.error(libc::ENOENT) };
        let (from, to) = (join(&p, name), join(&np, newname));
        match self.volume.rename(&from, &to) {
            Ok(()) => {
                if let Some(ino) = self.inodes.remove(&from) {
                    self.paths[ino as usize] = to.clone();
                    self.inodes.insert(to, ino);
                }
                reply.ok()
            }
            Err(e) => reply.error(errno(&e)),
        }
    }

    fn statfs(&mut self, _req: &Request, _ino: u64, reply: ReplyStatfs) {
        reply.statfs(0, 0, 0, 0, 0, 4096, 255, 4096)
    }
}

/// Mounts the drive in the background. Dropping the session unmounts it.
pub fn mount(volume: Arc<SmartVolume>, mount_point: &Path) -> anyhow::Result<fuser::BackgroundSession> {
    std::fs::create_dir_all(mount_point).ok();
    let options = [
        MountOption::FSName("slim".into()),
        MountOption::CUSTOM("volname=Slim".into()),
        MountOption::DefaultPermissions,
        MountOption::NoAtime,
    ];
    Ok(fuser::spawn_mount2(SlimFs::new(volume), mount_point, &options)?)
}
