# Arduino UNO Q Flasher (Web UI)

A web app that flashes multiple Arduino UNO Q boards in parallel over `adb`,
with live per-device logs and real-time status. Replaces the original
`unoq-flash-all.sh` bash workflow.

<img width="800" alt="Arduino UNO Q flasher UI" src="https://github.com/user-attachments/assets/f795a71a-c1b4-4a7b-a440-304114787171" />

## What's new in this version

- **WiFi only mode.** Sets just the WiFi network and nothing else, in seconds
  per board. It doesn't need the board's password, so it works on a board
  fresh from flashing.
- **Save a WiFi network for later.** Store a network the boards can't see yet,
  such as the venue's, and they join it automatically once it's in range.
- **Device passwords that actually change.** Handles the expired password a
  freshly flashed board ships with, checks that the new password works, and
  reports a real failure instead of a false success. A board with an unknown
  password can be unlocked with `UNOQ_CURRENT_PASSWORD`, and
  `probe-password.sh` finds which password it has.
- **No App Lab first-run questions.** `properties.msgpack` is now pushed even
  when no app folder is chosen, so App Lab doesn't ask for a password or
  board name, and boards can be given a name (fixed or random) with
  `UNOQ_BOARD_NAME`.
- **Docker images are kept.** They're only deleted when a board has less than
  1 GB free or Step 4 is ticked, so boards don't re-download App Lab's images
  (such as the Edge Impulse model runner) on every run.
- **The WiFi you enter is the WiFi the board gets.** Run saves unsaved WiFi
  settings first; the new network becomes the board's preferred one;
  passwords with symbols such as `$` arrive intact; and settings saved in the
  page take effect without restarting the server.
- **No silent hangs.** Quick `adb` commands time out with a clear message if a
  board stops responding, instead of stalling the run forever. Passwords are
  masked in the logs.

## Prerequisites

### Hardware

* [Amazon Basics 10 Port USB A Hub](https://www.amazon.es/-/en/Amazon-Basics-10-Port-Power-Adapter/dp/B076YRSWGW)
  (powered; see [ADB parallelism](#adb-parallelism--how-many-boards-can-i-flash-at-once))
* 10 USB-A to USB-C cables that carry data, not just power

### Software

- **Python 3.11+**
- **adb** (Android platform-tools) on your `PATH`
  - macOS: `brew install android-platform-tools`
  - Windows: download from <https://developer.android.com/studio/releases/platform-tools>
  - Linux: `sudo apt install adb`
- **`unoq-setup.sh`** present at the project root (pushed to each device).
- Optional **`properties.msgpack`** at the project root or inside the chosen
  app folder. It marks App Lab's first-run steps (keyboard, board name,
  password) as done, so App Lab doesn't ask for them. If present, it is pushed
  to:
  - `/home/arduino/.local/share/arduino-app-cli/properties.msgpack`
  - `/tmp/properties.msgpack`

### Settings (`.env`)

Settings live in `.env` at the project root. The WiFi SSID, WiFi password and
device password can be entered in Step 1 of the page, and **Save** writes them
there; the other settings are added by hand. The file is re-read on every run,
so changes apply without restarting the server. `.env` is in `.gitignore`;
never commit it.

```
UNOQ_WIFI_SSID="My Network"
UNOQ_WIFI_PASSWORD=wifi-password
UNOQ_DEFAULT_PASSWORD=device-password
```

| Setting | What it does |
| --- | --- |
| `UNOQ_WIFI_SSID` | WiFi network name the boards should use. |
| `UNOQ_WIFI_PASSWORD` | WiFi password (8–63 characters for WPA). |
| `UNOQ_DEFAULT_PASSWORD` | Password to set for the board's `arduino` user. Also used for `sudo` on the board. |
| `UNOQ_CURRENT_PASSWORD` | Optional. The password a board has **now**, if it's neither `arduino` nor `UNOQ_DEFAULT_PASSWORD` (for example, one set in App Lab). Lets the tool change it. |
| `UNOQ_BOARD_NAME` | Optional. `random` gives each board a friendly name such as `amber-heron-3f9c`; any other value is used as the name (letters, digits and hyphens, up to 64 characters, not starting with a hyphen). Unset leaves the name alone. Full setup only. |
| `UNOQ_WIFI_HIDDEN` | Optional. `1` if the network doesn't broadcast its name. Used by **Save for later**. |
| `UNOQ_WIFI_KEY_MGMT` | Optional. `sae` for a WPA3-only network. The default `wpa-psk` (WPA2) also joins mixed WPA2/WPA3 networks. Used by **Save for later**. |
| `UNOQ_FORCE_CLEANUP` | Optional. `1` deletes Docker images before every update, even with plenty of free space. |

## Install & run

```bash
# Ensure Python 3.11+ is used for the venv (required by this project).
# macOS (Homebrew) if missing: brew install python@3.11
python3.11 -m venv .venv
# Windows:
.venv\Scripts\activate
# macOS/Linux:
source .venv/bin/activate

# Optional but recommended: modern editable-install support
python -m pip install --upgrade pip
pip install -e .
python -m app
```

Open <http://localhost:8000>. Run `python -m app` from the project folder.
After updating the app's files, restart the server and hard-reload the page
(Cmd-Shift-R / Ctrl-Shift-R) so the browser doesn't keep the old version.

## Using the UI

1. **Connect** your UNO Q boards via USB. The device grid auto-refreshes every
   5 seconds — newly plugged boards appear without needing to click anything.
   You can also click **Refresh devices** to force an immediate poll, or
   **Check WiFi on all boards** to run a quick connectivity test fleet-wide.
2. (Optional) On each device card:
   - Click **Identify** to blink that board's red user LED for about 5 seconds.
   - Click **WiFi Check** to run a per-board network check (SSID, route, DNS,
     and HTTP reachability).
   - Watch the WiFi badge update (`WiFi ?` / `WiFi OK` / `WiFi Fail`).
3. In **Step 1 / WiFi credentials**, enter the SSID, WiFi password and
   (optionally) the device password, then answer **Is this network here now?**:
   - **Yes — connect now** joins the network during the run, which proves the
     password works. It fails if the network isn't in range.
   - **Not yet — save for later** stores the network so each board joins it
     automatically once it's in range. See [WiFi: connect now or save for later](#wifi-connect-now-or-save-for-later).

   Click **Save**, or just run: unsaved changes (shown as "unsaved — will be
   saved when you run") are saved automatically before the run starts. Tick
   **Skip** to leave each board's WiFi and password as they are.
4. In **Step 2**, click **Choose app folder** and pick the folder you want
   pushed to `/home/arduino/ArduinoApps/` on each device. The folder is
   uploaded once and reused for all selected devices. The UI lists any `.eim`
   model files found inside the folder so you can sanity-check the bundle
   before flashing. Tick **Skip** to keep the apps already on the boards.
5. (Optional) Edit **Post-update commands** as a multiline textbox.
   - One command per line.
   - Blank lines are ignored.
   - Lines starting with `#` are treated as comments.
   - Commands run in order and stop on first failure.
6. In **Step 3 / Run**, choose **Full setup** or **WiFi only** (see
   [Run modes](#run-modes)). For Full setup, select exactly which steps to run
   using the checkboxes (Step 1..Step 5) for this batch.
7. (Optional) Per device, tick **skip password**, **skip properties**, and/or
   **skip post-update** for fine-grained overrides.
8. Click **Run selected steps on all boards**. Each device card shows:
   - status badge (idle / running / success / failed)
   - progress bar across the workflow stages (selected steps show as run,
     skipped ones are marked skipped)
   - live-tailing log panel
9. If a device fails, click **Retry** on its card. A WiFi failure is retried
   once automatically, with `.env` pushed again.

The staged upload is removed from disk automatically once the run finishes.

## Run modes

| | **Full setup** | **WiFi only** |
| --- | --- | --- |
| What it does | WiFi, device password, app folder, App Lab properties, apt repair, system update, board name, Docker cleanup, post-update commands (each can be ticked on or off) | Sets the WiFi network and nothing else |
| Needs the board's password | Yes: it must be set (not expired) and known to the tool | No, so it works on a board fresh from flashing |
| Needs internet during the run | Yes | No |
| Time per board | Minutes | Seconds |

In WiFi only mode the Step 1–5 checkboxes are greyed out; the run pushes the
setup script and `.env`, and the script stops once WiFi is configured.

### WiFi: connect now or save for later

- **Connect now** runs `nmcli dev wifi connect`. The board switches to the
  network immediately, and the run fails with "WiFi network not found in
  range" if the network isn't there.
- **Save for later** writes a saved NetworkManager network with autoconnect
  on, without trying to connect. The board stays on its current network until
  the saved one comes into range. The password can't be checked until then;
  only its length (8–63 characters) is checked now. So test one board at the
  venue before relying on the rest. For hidden or WPA3-only networks, set
  `UNOQ_WIFI_HIDDEN` or `UNOQ_WIFI_KEY_MGMT` in `.env`.
- Full setup with **Save for later** still needs internet during the run
  through some other network, for the updates.

Either way, the configured network becomes the board's **preferred** network,
so it wins over older saved networks when several are in range (look for
"is now the preferred WiFi network" in the log). Re-running updates a saved
network in place rather than adding duplicates.

## Workflow (per device)

The web app has a 9-stage workflow. Any stage can be skipped by Step 3
selection (or per-device skip toggles where applicable). WiFi only runs just
`push_setup_script`, `push_env`, `chmod_script` and `run_setup`.

1. `push_app` — push chosen folder to `/home/arduino/ArduinoApps/`
2. `push_setup_script` — push `unoq-setup.sh` to `/home/arduino/.unoq-setup.sh`
3. `push_env` — push the settings from `.env` (if present locally) to
   `/home/arduino/.env`. The board gets a copy with every value quoted
   literally, so passwords containing `$`, backticks or quotes arrive exactly
   as typed.
4. `chmod_script` — make the setup script executable
5. `change_password` — set the arduino user's password to
   `UNOQ_DEFAULT_PASSWORD`. A freshly flashed board ships with its password
   expired, which blocks `sudo`; this stage clears that by setting the new
   password. It tries the current password in the order
   `UNOQ_CURRENT_PASSWORD`, `UNOQ_DEFAULT_PASSWORD`, `arduino`, then checks the
   new password really works. If none is accepted, or the board rejects the
   new password as too weak, the stage is marked failed with the reason. It
   doesn't fail the whole board, but later steps that need `sudo` will. See
   [Device passwords](#device-passwords). (skippable)
6. `push_properties` — push `properties.msgpack` to
   `/home/arduino/.local/share/arduino-app-cli/` and `/tmp/` so on-device
   setup-wizard markers are in place before setup runs. Runs whether or not an
   app folder is chosen. (skippable; skipped if absent)
7. `run_setup` — execute the remote setup script, which in order:
   1. turns on the WiFi radio and connects to, or saves, the network
   2. sets DNS to 8.8.8.8 and tests it (WiFi only stops here)
   3. waits for internet access
   4. makes any `.eim` models under `/home/arduino/ArduinoApps` executable
   5. clears caches; Docker images are deleted only if under 1 GB is free (or
      `UNOQ_FORCE_CLEANUP=1`), and the run stops if under 300 MB remains
   6. repairs a known broken package state (`alsa-ucm-conf`) if present;
      needs `sudo`
   7. runs `arduino-app-cli system update --yes --only-arduino`
   8. sets the board name if `UNOQ_BOARD_NAME` is set; needs `sudo`
8. `prune_docker_images` — Step 4: deletes **all** unused Docker/Podman images
   and stopped containers before post-update. App Lab downloads them again the
   next time an app runs, so leave it off unless boards are short of space
   (disabled by default)
9. `post_update` — run configured post-update commands on the device, one line
   at a time. Failures here are logged but do not mark the device as failed,
   since the flash itself is already done.

Quick `adb` commands time out after 2 minutes (5 minutes for file pushes) and
say so in the log. The setup script, Step 4 and post-update commands have no
time limit, since updates and image downloads can take a long time.

## Device passwords

The tool needs the board's password for `sudo`, which the apt repair and board
name use, and `sudo` refuses to run at all while the password is still expired.

- **Freshly flashed board:** the password is `arduino` and expired. The
  `change_password` stage sets it to `UNOQ_DEFAULT_PASSWORD`.
- **Board already on `UNOQ_DEFAULT_PASSWORD`:** nothing to change; the log says
  "Password is already set to the configured value."
- **Board on some other password** (set in App Lab, for example): the log
  shows "PASSWORD NOT CHANGED" and later "Cannot run apt remediation: sudo
  unavailable". Put that password in `.env` as `UNOQ_CURRENT_PASSWORD` and run
  again; the tool then changes it to `UNOQ_DEFAULT_PASSWORD`.

To find which password a board has, run `probe-password.sh` from the project
folder with the boards plugged in. It tries `arduino` and the passwords in
`.env`, then any guesses you add. A freshly flashed board is reported as
expired instead, since a normal run handles it.

```bash
bash probe-password.sh                              # every connected board
CANDIDATES="guess1,guess2" bash probe-password.sh   # also try your guesses
bash probe-password.sh SERIAL                       # one board
```

If nobody knows the password, reflash the board, which resets it to
`arduino`.

## Troubleshooting

| What you see | Likely cause | What to do |
| --- | --- | --- |
| "PASSWORD NOT CHANGED", then "Cannot run apt remediation: sudo unavailable" | The board's password is neither `arduino` nor `UNOQ_DEFAULT_PASSWORD` | See [Device passwords](#device-passwords). |
| "WiFi network not found in range" | The network isn't there, or the SSID is misspelled | Check the SSID. If the network doesn't exist yet, choose **Not yet — save for later**. |
| The board stays on its old network | The run didn't get the new SSID | Check the log's `UNOQ_WIFI_SSID=` line shows the new name, and look for "is now the preferred WiFi network". |
| A stage hangs, then "did not return after 120s" | The board dropped off USB or the adb server is stuck | Run `adb devices`, then `adb kill-server`; replug the board. Use a powered hub and a data cable. |
| App Lab still asks for a password or board name | `properties.msgpack` wasn't pushed, or the password wasn't set | Make sure `properties.msgpack` is in the project root, **skip properties** is unticked, and Step 1 ran without "PASSWORD NOT CHANGED". |
| `No module named app.__main__` | The `app` folder is incomplete (for example, replaced in Finder with a partial copy) | Restore the complete `app` folder, and run `python -m app` from the project folder. |
| The page looks unstyled or out of date | The browser kept old files | Hard-reload with Cmd-Shift-R / Ctrl-Shift-R. |
| "backend unreachable" | The server isn't running, or another copy holds port 8000 | Check the terminal running `python -m app`; `lsof -i :8000` shows what holds the port. |

## ADB parallelism — how many boards can I flash at once?

There are three different limits to keep in mind:

| Limit | Where | Practical impact |
| --- | --- | --- |
| **adb server transports** | `adb` itself | Historical 16-device cap; raised to 128 in platform-tools r30+. Not the bottleneck for typical fleets. |
| **USB host controller** | Your motherboard | Spec allows 127 devices per controller; each shares 480 Mbps (USB 2.0) or 5 Gbps (USB 3.x). A typical PC has 2–4 controllers. |
| **Bus bandwidth + power** | Your hubs | UNO Q draws real current. Bus-powered hubs sag past ~4 boards. Use **powered** hubs, and prefer splitting boards across multiple host ports / controllers. |

The Python side (`asyncio.gather` in `app/runs.py`) imposes no extra cap — every
device gets its own `adb` subprocess and they run concurrently. The wall-clock
bottleneck for this app is **parallel `adb push`**, which shares the USB
controller's bandwidth: 10 boards on one USB 2.0 controller will each get a
fraction of the ~30–40 MB/s the bus can push.

**Rule of thumb**: 8–16 boards per host machine is comfortable. For 32+
either split across multiple machines or add a PCIe USB controller and
distribute boards across separate controllers.
