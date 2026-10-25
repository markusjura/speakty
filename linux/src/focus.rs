//! The app in front, from Hyprland's IPC socket. Other compositors don't say, so this is None there.

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;

/// The focused window's class, such as "kitty".
pub fn focused_class() -> Option<String> {
    let mut socket = UnixStream::connect(socket_path()?).ok()?;
    socket.set_read_timeout(Some(Duration::from_millis(200))).ok()?;
    socket.write_all(b"j/activewindow").ok()?;
    let mut reply = String::new();
    socket.read_to_string(&mut reply).ok()?;
    let window: serde_json::Value = serde_json::from_str(&reply).ok()?;
    window.get("class")?.as_str().map(str::to_string)
}

fn socket_path() -> Option<PathBuf> {
    let runtime = PathBuf::from(std::env::var_os("XDG_RUNTIME_DIR")?);
    let signature = std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE")?;
    Some(runtime.join("hypr").join(signature).join(".socket.sock"))
}
