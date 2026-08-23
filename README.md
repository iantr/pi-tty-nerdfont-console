# pi-tty-nerdfont-console

**Beautiful text-mode consoles on a Raspberry Pi.**

Turning a Raspberry Pi into a **wall-mounted text terminal that actually looks good** —
Nerd Font glyphs, true colour, native panel resolution, tmux, and an auto-launching
full-screen TUI. No X, no Wayland compositor, no desktop.

The stock Linux virtual console can't do this. It renders a bitmap console font at a
fixed 8x16 cell, has no font fallback, and no ligature/glyph coverage — so any modern
TUI comes out as a field of `▯`. The fix is **[kmscon](https://github.com/Aetf/kmscon)**,
a KMS/DRM-based terminal emulator that replaces `agetty` on a VT and renders TrueType
fonts through Pango at the panel's real resolution.

This repo documents doing it on **two very different Pis**, because the two builds
diverge almost immediately:

| | `pi-zero` | `pi-4` |
|---|---|---|
| Board | Pi Zero 2 W | Pi 4 |
| OS | Raspberry Pi OS (Raspbian) trixie, **armhf** | Debian trixie, **arm64** |
| kmscon | `apt install kmscon` — one line | **no package exists**, build from source |
| DRM | one card, just works | **two cards**, kmscon picks the wrong one and hangs |
| Login hook | `tty`-based test | `tty` test **breaks on every restart** |
| Font size | 12 (small panel) | 14 (larger panel) |

![The pi-4 console: kmscon rendering a full-screen TUI with Nerd Font glyphs at native panel resolution](assets/console-pi4.png)

*An actual screenshot — not a photo of a monitor. Captured over SSH by reading
kmscon's DRM framebuffer out of `/dev/mem` with `scripts/grab-console.py`, since
kmscon never touches `/dev/fb0`. Note the box-drawing, disclosure triangles and
`❯` chevrons all rendering properly: on a stock Linux VT every one of those is a
`▯`.*

**[→ Read the full write-up: `ARTICLE.md`](ARTICLE.md)**

## Contents

```
ARTICLE.md                       the story, both builds, every trap and why it happens
configs/kmscon.conf              /etc/kmscon/kmscon.conf
configs/autologin.conf           systemd drop-in for kmsconvt@tty1
configs/tmux.conf                ~/.tmux.conf (the two lines that matter under kmscon)
configs/bashrc-hook.sh           the console-launch hook (the portable version)
configs/61-kmscon-v3d-offseat.rules   udev rule — Pi 4 dual-DRM fix
scripts/build-kmscon-arm64.sh    source build for 64-bit Debian
scripts/install-nerd-font.sh     system-wide Nerd Font install + verification
scripts/assistant-tui.sh         the launcher the console actually runs
scripts/preflight.sh             12-point verification checklist
scripts/test-on-spare-vt.sh      exercise the real unit on tty4, never on tty1
scripts/grab-console.py          screenshot the live console via DRM + /dev/mem
configs/wifi-powersave-off.conf  NetworkManager - the glitchy-typing fix
```

## Quick start

**64-bit Pi (`pi-4`):**
```bash
sudo bash scripts/build-kmscon-arm64.sh
sudo bash scripts/install-nerd-font.sh
sudo install -m644 configs/61-kmscon-v3d-offseat.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=drm --action=change
```

**32-bit Pi (`pi-zero`):**
```bash
sudo apt-get install -y kmscon tmux fontconfig
sudo bash scripts/install-nerd-font.sh
```

**Both, then:**
```bash
sudo install -m644 configs/kmscon.conf /etc/kmscon/kmscon.conf
sudo mkdir -p /etc/systemd/system/kmsconvt@tty1.service.d
sudo install -m644 configs/autologin.conf /etc/systemd/system/kmsconvt@tty1.service.d/
install -m644 configs/tmux.conf ~/.tmux.conf
cat configs/bashrc-hook.sh >> ~/.bashrc
sudo systemctl daemon-reload
sudo systemctl disable getty@tty1.service
sudo systemctl enable  kmsconvt@tty1.service
bash scripts/preflight.sh          # verify BEFORE rebooting
```

Edit `--autologin <user>` in `configs/autologin.conf` to match your account, and point
the launcher at whatever TUI you want on screen.

## Health signal worth knowing

```
tmux clients: /dev/pts/0: main [152x50 xterm-256color]
```

**152x50** means kmscon owns the display and is rendering at native resolution.
**80x23** means it isn't — that's the kernel framebuffer's default, i.e. nothing took
over the screen. The geometry alone tells you whether the build worked.

## Licence

MIT — see [LICENSE](LICENSE).
