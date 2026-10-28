#!/usr/bin/env bash
# Sets up a headless Ubuntu or Debian machine, such as the fleet machine l1, to build Speakty and run
# its checks: the build dependencies, Rust, access to the keyboards and /dev/uinput, and a headless
# Sway session with PipeWire, as user services that run without anyone logged in. Running it again
# brings a machine up to date with it.
# Usage: scripts/setup-test-host.sh
set -euo pipefail

sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends build-essential pkg-config curl ca-certificates git \
  libclang-dev libgtk-4-dev libadwaita-1-dev libgtk4-layer-shell-dev libpipewire-0.3-dev \
  sway pipewire pipewire-bin wireplumber dbus-user-session at-spi2-core jq grim kitty >/dev/null
[[ -x ~/.cargo/bin/cargo ]] || curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal

# Speakty reads the keyboards and types on a virtual one, as on a desktop.
echo 'KERNEL=="uinput", GROUP="input", MODE="0660", OPTIONS+="static_node=uinput"' | sudo tee /etc/udev/rules.d/70-speakty-uinput.rules >/dev/null
sudo udevadm control --reload && sudo udevadm trigger /dev/uinput
sudo usermod -aG input "$USER"
sudo loginctl enable-linger "$USER"

# Without a display there's no seat, so libseat's noop backend opens the input devices directly,
# which the input group allows, and Pixman draws without a GPU. Sway writes the variables clients
# need to a file instead of the user manager, so other user services don't land in this session.
mkdir -p ~/.config/speakty-test-session ~/.config/systemd/user
cat > ~/.config/speakty-test-session/sway.conf <<'SWAY'
# Speakty's headless test session, written by linux/scripts/setup-test-host.sh.
output HEADLESS-1 resolution 1920x1080
xwayland disable
exec env | grep -E '^(WAYLAND_DISPLAY|SWAYSOCK|XDG_CURRENT_DESKTOP)=' > "$XDG_RUNTIME_DIR/speakty-test-session.env"
SWAY
cat > ~/.config/systemd/user/speakty-test-session.service <<'UNIT'
# Written by linux/scripts/setup-test-host.sh.
[Unit]
Description=Headless Sway session for Speakty's checks
Wants=pipewire.socket wireplumber.service
After=pipewire.socket wireplumber.service

[Service]
Environment=WLR_BACKENDS=headless,libinput WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman LIBSEAT_BACKEND=noop XDG_CURRENT_DESKTOP=sway
ExecStart=/usr/bin/sway -c %h/.config/speakty-test-session/sway.conf
ExecStopPost=/usr/bin/rm -f %t/speakty-test-session.env
Restart=on-failure

[Install]
WantedBy=default.target
UNIT
systemctl --user daemon-reload
systemctl --user enable --now pipewire.socket wireplumber.service
systemctl --user enable speakty-test-session.service
systemctl --user restart speakty-test-session.service

# Group changes reach only processes started after them, and the user manager started at boot.
if ! grep -qw "$(getent group input | cut -d: -f3)" <(grep '^Groups:' "/proc/$(systemctl --user show -p MainPID --value speakty-test-session.service)/status"); then
  echo "Restart the user manager, or the machine, so the session joins the input group:"
  echo "  sudo systemctl restart user@$(id -u).service   # restarts every user service"
  echo "Then run this script again."
  exit 1
fi
echo "The test session runs. Check it from the Mac: linux/scripts/remote.sh -- 'cargo run --quiet --bin speakty-ui -- workspace'"
