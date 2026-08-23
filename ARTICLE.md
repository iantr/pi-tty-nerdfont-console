# A Raspberry Pi as a beautiful text-mode terminal for your home AI assistant

*Nerd Font glyphs, true colour and native panel resolution on a bare Linux console —
no X, no Wayland, no desktop. Built twice: once on a Pi Zero 2 W, once on a Pi 4,
and the two builds diverge almost immediately.*

---

## Why bother

I wanted a small always-on screen on the wall that does exactly one thing: show a
full-screen terminal UI for a self-hosted AI assistant. Type at it, get an answer,
walk away. No mouse, no browser, no login screen, no desktop environment eating
300 MB of RAM to draw one terminal.

The obvious answer is the Linux virtual console — it's already there, it boots in
two seconds, and it costs nothing. The problem is that it's *ugly*, and in a very
specific way that matters here:

- It renders a **bitmap console font** at a fixed 8x16 cell. No TrueType, no Pango,
  no font fallback.
- The glyph repertoire is capped at **512 glyphs** by the VGA-derived font format.
- Which means every powerline separator, every rounded box-drawing corner, every
  spinner, every status-bar icon that modern TUIs are built out of renders as `▯`.

That last point is the whole reason this project exists. AI assistant TUIs lean
*hard* on Nerd Font glyphs — thinking spinners, tool-call icons, model badges,
powerline-style prompt segments, box-drawn message frames. On a stock VT the
interface is a field of tofu boxes and it's genuinely unpleasant to use. On a
console that can render a real Nerd Font it looks as good as a terminal on a
desktop, on a $15 board, with a two-second boot.

The tool that gets you there is **[kmscon](https://github.com/Aetf/kmscon)** — a
terminal emulator that talks directly to KMS/DRM, renders TrueType fonts through
Pango, and runs *as* the VT instead of on top of one. You point systemd at
`kmsconvt@tty1` instead of `getty@tty1` and the console is simply better.

Everything from here is what actually went wrong, on two boards, and why.

---

## The 32-bit build: `pi-zero`

Pi Zero 2 W, Raspberry Pi OS Lite (Raspbian trixie, armhf). This one is easy, and
it's worth reading first because the 64-bit build is defined by how it *differs*.

```bash
sudo apt-get update
sudo apt-get install -y kmscon tmux fontconfig
```

Install a Nerd Font system-wide (`/usr/local/share/fonts/nerd-fonts/`), then:

```ini
# /etc/kmscon/kmscon.conf
font-name=CaskaydiaCove Nerd Font Mono
font-size=12
font-engine=pango
xkb-layout=us
```

`font-engine=pango` is the load-bearing line — that's what makes it a TrueType
renderer instead of a bitmap one.

### Verify the font by resolution, not by presence

The single most common way to get this wrong is to copy a `.ttf` into place, see
the file on disk, and assume it's working. fontconfig may still not match it, in
which case kmscon silently falls back to something else and the console looks
*subtly* wrong — glyphs present but proportions off, or tofu returning in places.

```bash
fc-match "CaskaydiaCove Nerd Font Mono"
# CaskaydiaCoveNerdFontMono-Regular.ttf: "CaskaydiaCove Nerd Font Mono" "Regular"
```

If that echoes back `DejaVuSans.ttf`, fontconfig did not find your font. **File
exists ≠ font resolves.** Same class of mistake as `ls`-ing a systemd unit and
assuming systemd can see it (which bites us later, hard).

### Autologin drop-in

```ini
# /etc/systemd/system/kmsconvt@tty1.service.d/autologin.conf
[Service]
ExecStart=
ExecStart=/usr/bin/kmscon "--vt=%I" --seats=seat0 --no-switchvt --login \
  -- /sbin/agetty --autologin pi --noclear - xterm-256color
```

The empty `ExecStart=` first is required — systemd needs it to clear the inherited
value before you set a new one.

### tmux under kmscon

```
# ~/.tmux.conf
set-option -g default-command bash
set-environment -gru DBUS_SESSION_BUS_ADDRESS
```

and export `TMUX_SYSTEMD=0` before launching. Without it, tmux tries to create a
systemd cgroup scope for the session, which fails under a kmscon login, and the
session dies at birth.

### And one non-obvious performance trap: WiFi power save

Once it was running, typing at the console felt **glitchy** — not slow, glitchy.
Bursts of characters would land, then a stall, then a catch-up. The same session
over SSH from a laptop was perfectly smooth.

The cause was `power_save on` on `wlan0` — the Raspbian default. With a DTIM
period of 3 and a 100 ms beacon interval, the radio parks between beacons and only
wakes on the AP's ~300 ms schedule.

It hits *typing* specifically and nothing else, and the reason is worth
understanding: bulk transfer is fine, because once data flows the radio stays
awake. Interactive SSH is the pathological case — tiny packets separated by
human-length pauses, and SSH echoes **every keystroke as its own round trip**. So
each character after a pause can wait for the next DTIM window. Type a burst and
the radio wakes mid-word. Glitchy, not uniformly slow.

Measured on the Pi Zero at **-39 dBm** (excellent signal):

| test | power_save ON | power_save OFF |
|---|---|---|
| 12 back-to-back pings, max | **1220 ms** | **9.9 ms** |
| 12 back-to-back pings, avg | 457 ms | 4.1 ms |
| after 2 s idle, worst | 205 ms | 13.9 ms |

A **780x latency swing on a link with excellent signal.** Don't read a big latency
spread as weak signal or a congested channel — check `power_save` first.

```bash
/usr/sbin/iw dev wlan0 get power_save          # note: /usr/sbin, often not on $PATH
sudo /usr/sbin/iw dev wlan0 set power_save off # immediate, no reconnect needed
```

⚠️ **The runtime setting alone is not enough.** NetworkManager re-applies its own
value on every (re)connect, silently undoing it at the next reboot or
reassociation. Persist it:

```ini
# /etc/NetworkManager/conf.d/wifi-powersave-off.conf
[connection]
wifi.powersave = 2      # 2 = force off, 3 = force on, 0 = default
```

then `nmcli general reload conf` — which reloads without dropping the link, which
matters a lot when you are connected *over* that link. Expect a brief blip anyway:
mine went unreachable for under 45 seconds (still associated at -41 dBm with frames
flowing, but no IP) and recovered on its own. **Wait it out; don't re-probe in a
loop.**

Honest end state, 60 pings steady: p50 2.1 ms, p90 5.7 ms, 96% under 20 ms — but
p99 178 ms, one outlier over 100 ms in 55. The structural, repeatable power-save
stall is gone. Occasional outliers remain and are a different mechanism (neighbour
airtime — 17–23% OBSS on that channel). The fix is *"the 1220 ms stalls are gone"*,
not *"latency solved"*.

Cost of disabling power save: roughly 30–60 mW. Irrelevant on a mains-powered wall
console.

---

## The 64-bit build: `pi-4`

Same goal, wired Ethernet, bigger panel, more RAM. Every single step of the above
that mattered broke differently.

### Trap 1 — there is no `kmscon` package for arm64

```
$ sudo apt-get install kmscon
E: Unable to locate package kmscon
```

This reads like a broken mirror or a missing suite. It isn't. Check where the
*working* host gets it from:

```
$ apt-cache policy kmscon        # on the 32-bit Pi, where it installs fine
 *** 9.0.0-5+b1 500
        500 http://raspbian.raspberrypi.com/raspbian trixie/main armhf Packages
                                                             ^^^^^
```

kmscon comes from the **Raspbian armhf** archive. A 64-bit Pi runs plain Debian
arm64 (`deb.debian.org` plus `archive.raspberrypi.com`), and **Debian proper dropped
kmscon years ago** — there is no arm64 binary in any configured suite. `apt-get
source kmscon` fails too, because the arm64 sources.list has no `deb-src` lines.

> **Lesson: "package not found" on a Pi is usually an *architecture* story, not a
> mirror story.** Ask the working host which suite it pulled from.

So: build from source. It takes about two minutes on a Pi 4.

### Trap 1b — pin the version to what your libtsm supports

Building `HEAD` / v9.1.0 on trixie fails at configure:

```
Dependency libtsm found: NO. Found 4.0.2 but need: '>=4.1.0'
```

Debian trixie ships libtsm 4.0.2. Build **v9.0.0** instead — which is also the exact
version the armhf package provides, so both consoles end up on identical behaviour.
Don't chase the newer tag and don't hand-build libtsm: *version-matching the working
host is the entire point*.

```bash
sudo apt-get install -y build-essential meson ninja-build pkg-config \
  libudev-dev libxkbcommon-dev libdrm-dev libgbm-dev libegl-dev \
  libgles2-mesa-dev libpango1.0-dev libtsm-dev libsystemd-dev libpixman-1-dev git

git clone --depth 1 --branch v9.0.0 https://github.com/Aetf/kmscon.git
cd kmscon
meson setup build --prefix=/usr     # confirm 'font_pango : true' in the summary
ninja -C build                      # 84/84 targets
sudo ninja -C build install
```

Check the meson summary for **`font_pango : true`**. That's the engine
`font-engine=pango` needs; without it your Nerd Font never renders and you're back
to tofu.

### Trap 1c — meson installs the systemd units where systemd can't see them

```
Installing .../kmscon.service    to /usr/lib/aarch64-linux-gnu/systemd/system
Installing .../kmsconvt@.service to /usr/lib/aarch64-linux-gnu/systemd/system
```

That's a **multiarch** path, and systemd does not scan it. The symptom is
maddening: `systemctl cat kmsconvt@tty1` prints *nothing at all*, and your carefully
written drop-in appears to do nothing. Easy to misdiagnose as a bad drop-in.

```bash
sudo cp /usr/lib/aarch64-linux-gnu/systemd/system/kmscon.service \
        /usr/lib/aarch64-linux-gnu/systemd/system/kmsconvt@.service \
        /usr/lib/systemd/system/
sudo systemctl daemon-reload
systemctl cat kmsconvt@tty1 | grep ExecStart    # must now print
```

> **`systemctl cat` is the proof a unit exists — not `ls`.** File-on-disk is not the
> same as unit-is-visible, exactly like `fc-match` vs a `.ttf` on disk.

### Trap 2 — the Pi 4 has two DRM cards and kmscon grabs the wrong one

It builds, it starts, it dies:

```
ERROR: video_drm2d: driver does not support dumb buffers
       (video_init() in ../src/uterm_drm2d_video.c:335)
```

This reads like a missing or broken graphics driver. It isn't. The Pi 4 exposes two
DRM devices and **only one of them drives a display**:

```bash
udevadm info -q property -n /dev/dri/card0 | grep ID_PATH
#   ID_PATH=platform-fec00000.v3d      <- V3D, render-only, NO connectors
udevadm info -q property -n /dev/dri/card1 | grep ID_PATH
#   ID_PATH=platform-gpu               <- VC4 display controller

ls /sys/class/drm/ | grep ^card
#   card0
#   card1
#   card1-HDMI-A-1      <- both HDMI ports hang off card1
#   card1-HDMI-A-2
#   card1-Writeback-1
```

The **`card1-HDMI-A-*` connector entries are the authoritative tell** for which card
owns the outputs. Enumerate `/sys/class/drm/` rather than assuming `card0`.

### Trap 2b — and the obvious fix is wrong

`kmscon --help` advertises `--gpus={all,aux,primary}`, so `--gpus=primary` looks
like the answer. It makes the crash go away.

**It is the wrong fix, and it produces something much worse than a crash: a console
that looks exactly like a boot hang.** The screen freezes on the last kernel message
and stays there forever.

Here's why. `primary` means *the boot-VGA device* — a **PCI** concept. Both Pi DRM
nodes are **platform** devices and neither has a `boot_vga` attribute at all:

```bash
for c in /sys/class/drm/card0 /sys/class/drm/card1; do
  echo "$c boot_vga=$(cat $c/device/boot_vga 2>/dev/null || echo n/a)"
done
#   /sys/class/drm/card0 boot_vga=n/a
#   /sys/class/drm/card1 boot_vga=n/a
```

`primary` matches **zero** GPUs. So kmscon starts, takes the VT, spawns the login
shell — which means SSH and `tmux ls` both look perfectly healthy — and **never opens
a DRM device at all.** It draws nothing, and the kernel framebuffer's last line of
text just sits there.

**The decisive probe: count video file descriptors.** `systemctl is-active` returning
`active` proves nothing here.

```bash
PID=$(pgrep -f 'kmscon --vt=tty1' | head -1)
sudo sh -c "readlink /proc/$PID/fd/* 2>/dev/null" | grep -E '^/dev/(dri|fb)'
#   /dev/dri/card1        <- healthy: it holds the DISPLAY controller
#   (no output)           <- drawing to NOTHING
```

Zero on a running console is the whole diagnosis. Healthy is non-zero.

☠️ **Two ways to get a false alarm out of this probe, both of which report a
perfectly healthy console as broken** — and since the output is indistinguishable
from the real failure, they'll send you chasing a bug that doesn't exist:

- **`sudo lsof -p "$PID"`** can come back with essentially nothing for a root-owned
  process depending on how it's invoked (I hit this over sudo-on-SSH: one line of
  output, zero matches, console completely fine). The `/proc` symlinks are the
  authoritative source; `lsof` is a convenience wrapper over them.
- **`sudo readlink /proc/$PID/fd/*`** — the glob expands **as the calling user,
  before `sudo` runs**. You can't read that root-owned directory, so it silently
  matches nothing and prints nothing. The glob has to expand *inside* the
  privileged shell, hence `sudo sh -c "..."` above.

> **A health check that can only ever say FAIL is worse than no check.** Validate
> any probe against a machine you *know* is healthy before you trust its verdict on
> a broken one.

☠️ One more thing that made this hard to see: **a background VT never spawns its
login**, so a test on tty4 shows no children and no DRM fds *even when the config is
correct*. You have to `sudo chvt 4` to make the test meaningful. That's precisely
what made the `--gpus` variants look indistinguishable in a background-only test.

With `--gpus=all` and the VT actually foregrounded, the real error finally appears:

```
ERROR: drm_shared: cannot retrieve drm resources
       (uterm_drm_video_hotplug() in ../src/uterm_drm_shared.c:665)   # forever
```

kmscon opened **card0** — the render-only V3D node, no CRTCs, no connectors — and
spins there. It does **not** fall through to card1. `--gpus=aux` is no better.

### Trap 2c — the actual fix is a udev seat rule

Stop the render-only node from being a seat0 login device at all. Note that
`TAG-="seat"` does **not** work — the tags come straight back. Reassign `ID_SEAT`:

```
# /etc/udev/rules.d/61-kmscon-v3d-offseat.rules
SUBSYSTEM=="drm", KERNEL=="card0", ENV{ID_PATH}=="platform-fec00000.v3d", ENV{ID_SEAT}="seat-v3d"
```

```bash
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=drm --action=change
loginctl seat-status seat0 | grep -oE 'drm:card[0-9]+$' | sort -u   # must print ONLY drm:card1
```

Then **revert `ExecStart` to `--gpus=all`**. The rule fixes the enumeration; the flag
was never the answer.

⚠️ Removing the rule while kmscon is running makes it **segfault immediately** —
card0 reappears underneath it. Stop the unit before touching the rule.

### Trap 3 — the login hook keyed off a hardcoded pty number

Video fixed, and the console still died instantly on every restart. The culprit was
in `~/.bashrc`, and it's the mistake I'd bet is most widely copy-pasted:

```bash
if [ "$(tty)" = "/dev/pts/0" ] && [ -z "$TMUX" ]; then   # ☠️ pts NUMBER is not stable
```

kmscon's login shell gets whatever pty is free. The **first** login after boot gets
`pts/0` and works beautifully. Every restart after that lands on `pts/1`, `pts/2`…
the test fails, the shell falls through to an interactive prompt, exits, and the
console dies. This is why *"it worked when I built it"* and *"it's frozen at boot"*
were both true statements about the same machine.

Key off the **logind seat** instead — SSH sessions have no `XDG_SEAT` — and use
`new-session -A` so a restart re-attaches rather than failing on the existing
session:

```bash
if [ -z "${TMUX:-}" ] && [ -z "${SSH_CONNECTION:-}" ] && [ -n "${XDG_SEAT:-}" ]; then
    export TMUX_SYSTEMD=0
    exec tmux -f ~/.tmux.conf new-session -A -s main ~/assistant-tui.sh
fi
```

Confirm the variable really is exported into the console shell before trusting it:

```bash
PID=$(pgrep -f 'kmscon --vt=tty1' | head -1)
SH=$(pgrep -P $(pgrep -P "$PID" | head -1) | head -1)
sudo tr '\0' '\n' < /proc/$SH/environ | grep -E 'XDG_SEAT|SSH_CONNECTION'
#   XDG_SEAT=seat0
```

### Trap 3b — `.bash_profile` silently shadows `.profile`

The console shell is a **login** shell (`-bash`). Debian's chain is
`.profile` → sources `.bashrc`. But bash reads `.bash_profile` **in preference to**
`.profile`, so creating even an **empty** `~/.bash_profile` breaks the whole chain
and your hook never runs — with no error anywhere.

I did this to myself with a throwaway probe script that did
`cp ~/.bash_profile /tmp/bp.bak 2>/dev/null || touch /tmp/bp.bak` and then
"restored" it — **creating** a file that had never existed and killing the console.

> **Never `touch` a dotfile you are only trying to back up.** Test for existence, and
> restore *absence* as carefully as you restore content.

---

## Testing without bricking the console you're standing in front of

tty1 is the live console, and on my Pi 4 the box has a second job (it's the
coordinated-shutdown master for a UPS), so casual reboots aren't free. Exercise the
**exact same unit on a spare VT** instead:

```bash
sudo mkdir -p /etc/systemd/system/kmsconvt@tty4.service.d
sudo cp /etc/systemd/system/kmsconvt@tty1.service.d/autologin.conf \
        /etc/systemd/system/kmsconvt@tty4.service.d/
sudo systemctl daemon-reload
sudo systemctl start kmsconvt@tty4.service
sleep 6
systemctl is-active kmsconvt@tty4
ps aux | grep [k]mscon       # confirm the FLAGS you think you're testing are present
sudo journalctl -u kmsconvt@tty4 --since -1min --no-pager -o cat
```

☠️ **The pitfall that cost me a full cycle:** my first tty4 test reproduced the
dumb-buffers error *even after* applying a fix — because the drop-in lived in
`kmsconvt@tty1.service.d`, i.e. **tty1 only**, so tty4 was running the stock
`ExecStart`. `ps aux` showed the flags missing and gave it away.

> **Always confirm the running process's actual argv matches what you believe you are
> testing.**

Keep tty2–tty6 on their normal gettys. That's your escape hatch (Ctrl+Alt+F2) if the
console comes up wrong, on top of SSH.

Two more self-inflicted wounds from the same debugging session, offered freely:

- `sudo pkill -f 'kmscon --vt=tty4'` **killed the SSH session running it** — the
  pattern matched the `bash -c` command string carrying it. Put teardown in a script
  file, or use a pattern that can't match its own invocation.
- `/usr/bin/kmscon` is a **shell wrapper**, not the ELF. `gdb /usr/bin/kmscon` says
  `not in executable format`. The real binary with symbols is
  `/usr/libexec/kmscon/kmscon`.
- `--drm=off` is invalid syntax (`Option takes no arg`). kmscon booleans negate with a
  `no-` prefix: `--no-drm`.

---

## Switching tty1 over, and knowing it worked

```bash
sudo systemctl disable getty@tty1.service
sudo systemctl enable  kmsconvt@tty1.service
systemctl is-enabled getty@tty1 kmsconvt@tty1     # disabled / enabled
```

Healthy end state on the Pi 4:

```
kmscon --vt=tty1 ... --gpus=all
 \_ login -- pi
     \_ tmux -f ~/.tmux.conf new-session -A -s main ~/assistant-tui.sh
tmux: main: 1 windows (attached)
clients: /dev/pts/0: main [152x50 xterm-256color] (attached,focused,UTF-8)
```

★ **The client geometry is itself a health signal.** `152x50` means kmscon is
rendering at the panel's native resolution. The broken runs all showed `80x23` — the
kernel framebuffer's default, i.e. nobody had taken over the display. You can tell
whether the build worked from the tmux client list alone.

And confirm the fallback did *not* take over:

```bash
systemctl is-active getty@tty1      # must be: inactive
```

`kmsconvt@.service` ships `OnFailure=getty@%i.service`, so **a plain login prompt
with a blinking cursor on the console means kmscon crashed and agetty replaced it.**
That prompt is a failure indicator, not a success one — which is genuinely
counterintuitive when you're staring at a working-looking terminal.

### Full preflight

| # | Check | Command |
|---|---|---|
| 1 | kmscon binary present | `ls -l /usr/bin/kmscon` |
| 2 | font **resolves** | `fc-match "CaskaydiaCove Nerd Font Mono"` |
| 3 | kmscon.conf correct | `cat /etc/kmscon/kmscon.conf` |
| 4 | tmux installed | `tmux -V` |
| 5 | launcher executable | `test -x ~/assistant-tui.sh` |
| 6 | bashrc hook present exactly once | `grep -c assistant-tui.sh ~/.bashrc` |
| 7 | unit resolves | `systemctl cat kmsconvt@tty1 \| grep ExecStart` |
| 8 | seat0 has only the display card | `loginctl seat-status seat0 \| grep drm:` |
| 9 | tty1 ownership | `systemctl is-enabled getty@tty1 kmsconvt@tty1` |
| 10 | kmscon holds video fds | `sudo sh -c "readlink /proc/PID/fd/*" \| grep /dev/dri` |
| 11 | fallback getty not active | `systemctl is-active getty@tty1` |

`scripts/preflight.sh` runs all of these.

---

## Odds and ends

**Copy the font from a working console instead of re-downloading.** Guarantees an
identical look across machines and skips a release download:

```bash
scp pi@pi-zero:/usr/local/share/fonts/nerd-fonts/CaskaydiaCoveNerdFontMono-*.ttf /tmp/nf/
scp /tmp/nf/*.ttf pi@pi-4:/tmp/
ssh pi@pi-4 'sudo mkdir -p /usr/local/share/fonts/nerd-fonts &&
             sudo install -m644 -o root -g root /tmp/*.ttf /usr/local/share/fonts/nerd-fonts/ &&
             sudo fc-cache -f && fc-match "CaskaydiaCove Nerd Font Mono"'
```

**Font size is a taste setting tied to the physical panel, not a fleet constant.**
The Pi Zero drives a small screen at `font-size=12`; the Pi 4 drives a larger,
sharper one and wanted `14`. One line in `kmscon.conf`, change it freely.

**Screen blanking** without sudo, in `.bashrc`:

```bash
setterm --blank 10 --powerdown 15 2>/dev/null
```

Blanks after 10 idle minutes, DPMS powerdown at 15, any keypress wakes it. `setterm`
only affects the current terminal, hence putting it in `.bashrc`; the `2>/dev/null`
keeps it quiet when the file is sourced over SSH.

**Scheduled hard on/off** is different, and on the modern KMS driver
(`vc4-kms-v3d`) the usual advice is wrong: **`vcgencmd display_power 0/1` is a
no-op** — it always reports `1` and never toggles. `tvservice` is gone entirely. The
real lever is the framebuffer blank node:

```bash
echo 1 > /sys/class/graphics/fb0/blank    # off  (1 or 4)
echo 0 > /sys/class/graphics/fb0/blank    # on
```

It's root-owned, so schedule it from **root's crontab** — no runtime password needed
once installed. Note this is a hard off, not an idle blank: a keypress will *not*
wake it.

**If the Pi has a second job, check it after every step, not just at the end.** Mine
runs NUT for UPS-triggered shutdown; `systemctl is-active ups-trigger.path
nut-monitor nut-server` went into the loop alongside the console checks. And don't
reboot to validate — everything above was verified live on a spare VT with the box
up. Save the reboot for when you're physically at the keyboard.

---

## Bonus: screenshotting a console that has no X server

You can't `import` or `scrot` a bare VT, and on this Pi you can't use `fbgrab`
either — `/dev/fb0` reads `blank=4` (powered down) with **zero** processes
holding it, because kmscon renders through DRM/KMS and never touches the
framebuffer device. Grab it there instead. DRM debugfs names the live buffer:

```bash
sudo cat /sys/kernel/debug/dri/1/framebuffer
#   framebuffer[725]:
#       allocated by = kmscon
#       format=XR24 little-endian
#       size=1680x1050
#       pitch[0]=6720
#       dma_addr=0x00000000cfb00000
```

That `dma_addr` lets you read the pixels straight out of `/dev/mem` (needs
`CONFIG_STRICT_DEVMEM` unset, which is the default here). `scripts/grab-console.py`
does exactly that and writes a PNG using only `zlib` + `struct` — no dependencies
on the Pi.

☠️ **The trap: on the Pi 4 `dma_addr` is a VideoCore BUS address, not a CPU
physical address.** Read it verbatim and you get unrelated RAM — which decodes to
*convincing colour noise*, not an obviously-broken black frame. I shipped one of
those before looking at it. Strip the alias:

```python
BUS_ALIAS = 0xC0000000
phys = DMA - BUS_ALIAS if DMA >= BUS_ALIAS else DMA
```

★ **The cheap tell is compressibility.** A console screen is mostly flat
background and compresses hugely; random memory doesn't:

| capture | PNG size | zlib ratio |
|---|---|---|
| wrong address (noise) | 3.7 MB | 0.985 |
| correct address (console) | 88 KB | **0.005** |

The script computes that ratio and warns you when a capture looks like noise, so
it can't silently hand you garbage. Which is the same lesson as the preflight bug
above, in a different costume: **`rc=0` and a valid 1680x1050 PNG were both true
of the broken capture.** Verify the artifact, not the exit code.

---

## The five things worth carrying away

1. **"Package not found" on a Pi is usually an architecture story, not a mirror
   story.** Ask the working host which suite it pulled from (`apt-cache policy`).
2. **Version-match the working host when building from source.** The newest tag is
   not the goal; identical behaviour across machines is.
3. **Enumerate `/sys/class/drm/` before blaming the graphics driver.** Multiple DRM
   cards where only one has connectors is normal on the Pi 4, and "does not support
   dumb buffers" is what picking the render-only node looks like.
4. **Existence is not resolution.** `fc-match` proves a font, `systemctl cat` proves
   a unit, counting `/dev/dri` fds proves a display. `ls` proves nothing.
5. **Never key a login hook off a pty number.** Use `XDG_SEAT`.

The payoff is worth all of it: a silent, fanless board on the wall, booting straight
into a full-screen terminal with proper glyphs and true colour, ready to answer
questions. No desktop, no browser, no login screen.

---

*Configs and scripts for both builds are in this repo. MIT licensed — take what's
useful.*
