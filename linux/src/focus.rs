//! The app in front, from Hyprland's or Sway's IPC socket. Other compositors don't say, so this is
//! None there.

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;

/// The focused window's class or app ID, such as "kitty".
pub fn focused_class() -> Option<String> {
    if let Some(signature) = std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE") {
        let runtime = PathBuf::from(std::env::var_os("XDG_RUNTIME_DIR")?);
        return hyprland_class(runtime.join("hypr").join(signature).join(".socket.sock"));
    }
    sway_class(PathBuf::from(std::env::var_os("SWAYSOCK")?))
}

fn connect(path: PathBuf) -> Option<UnixStream> {
    let socket = UnixStream::connect(path).ok()?;
    socket.set_read_timeout(Some(Duration::from_millis(200))).ok()?;
    Some(socket)
}

fn hyprland_class(path: PathBuf) -> Option<String> {
    let mut socket = connect(path)?;
    socket.write_all(b"j/activewindow").ok()?;
    let mut reply = String::new();
    socket.read_to_string(&mut reply).ok()?;
    let window: serde_json::Value = serde_json::from_str(&reply).ok()?;
    window.get("class")?.as_str().map(str::to_string)
}

/// Asks Sway for its tree with the i3 IPC protocol: a magic string, the payload's length, and the
/// message type, in native byte order.
fn sway_class(path: PathBuf) -> Option<String> {
    const MAGIC: &[u8] = b"i3-ipc";
    const GET_TREE: u32 = 4;
    let mut socket = connect(path)?;
    socket.write_all(&[MAGIC, &0u32.to_ne_bytes(), &GET_TREE.to_ne_bytes()].concat()).ok()?;
    let mut header = [0; 14];
    socket.read_exact(&mut header).ok()?;
    let length = u32::from_ne_bytes(header[6..10].try_into().ok()?) as usize;
    let mut reply = vec![0; length];
    socket.read_exact(&mut reply).ok()?;
    focused_app(&serde_json::from_slice(&reply).ok()?)
}

/// The focused node's app ID, or its X11 class when it runs in Xwayland.
fn focused_app(node: &serde_json::Value) -> Option<String> {
    if node["focused"] == true {
        let app = node["app_id"].as_str().or(node["window_properties"]["class"].as_str());
        return app.map(str::to_string);
    }
    ["nodes", "floating_nodes"].iter().flat_map(|key| node[key].as_array().into_iter().flatten()).find_map(focused_app)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_the_focused_window_in_a_sway_tree() {
        let tree = serde_json::json!({
            "focused": false,
            "nodes": [{
                "focused": false,
                "nodes": [{ "focused": false, "app_id": "org.gnome.TextEditor" }],
                "floating_nodes": [{ "focused": true, "app_id": null, "window_properties": { "class": "XTerm" } }]
            }]
        });
        assert_eq!(focused_app(&tree).as_deref(), Some("XTerm"));
    }
}
