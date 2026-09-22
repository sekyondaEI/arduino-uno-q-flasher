#!/bin/bash

# ── Timer & error tracking ────────────────────────────────────────────────────
START_TIME=$(date +%s)
ERRORS=()

log() {
    echo "[UNOQ-SETUP] $1"
}

add_error() {
    ERRORS+=("$1")
    log "ERROR: $1"
}

print_summary() {
    END_TIME=$(date +%s)
    ELAPSED=$((END_TIME - START_TIME))
    MINS=$((ELAPSED / 60))
    SECS=$((ELAPSED % 60))
    echo ""
    echo "╔══════════════════════════════════════════════════╗"
    echo "║              UNOQ-SETUP SUMMARY                  ║"
    echo "╠══════════════════════════════════════════════════╣"
    printf "║  Total time : %02dm %02ds%-32s║\n" "$MINS" "$SECS" ""
    if [ ${#ERRORS[@]} -eq 0 ]; then
        echo "║  Status     : SUCCESS                            ║"
    else
        printf "║  Status     : FAILED (%d error(s))%-17s║\n" "${#ERRORS[@]}" ""
        echo "╠══════════════════════════════════════════════════╣"
        echo "║  Errors:                                         ║"
        for ERR in "${ERRORS[@]}"; do
            printf "║    • %-44s║\n" "$ERR"
        done
    fi
    echo "╚══════════════════════════════════════════════════╝"
}

# Always print summary on exit (normal or error)
trap print_summary EXIT

# ── Load environment variables ────────────────────────────────────────────────
# The flasher passes the per-run choices (UNOQ_WIFI_MODE, UNOQ_WIFI_ONLY) on
# the command line. Capture them before sourcing .env so a stale value in the
# file can't override what was picked in the web UI for this run.
RUN_WIFI_MODE="${UNOQ_WIFI_MODE:-}"
RUN_WIFI_ONLY="${UNOQ_WIFI_ONLY:-}"
if [ -f /home/arduino/.env ]; then
    log "Loading /home/arduino/.env file..."
    set -a
    . /home/arduino/.env
    set +a
    # Show which settings arrived, but never print password values.
    env | grep '^UNOQ_' | sed -E 's/^(UNOQ_[A-Z_]*PASSWORD[A-Z_]*=).*/\1********/'
else
    log "/home/arduino/.env file not found."
fi

log "Checking WiFi credentials..."
if [ -z "$UNOQ_WIFI_SSID" ] || [ -z "$UNOQ_WIFI_PASSWORD" ]; then
    add_error "UNOQ_WIFI_SSID and UNOQ_WIFI_PASSWORD environment variables must be set."
    exit 1
fi

CURRENT_USER=$(whoami)
log "Current user: $CURRENT_USER"
if [ "$CURRENT_USER" != "arduino" ]; then
    add_error "Current user is not arduino, this device is too far out of date or the user has been modified. Please flash the latest image from https://docs.arduino.cc/tutorials/uno-q/update-image/ and run this setup script again."
    exit 1
fi

log "Updating PATH..."
export PATH=$PATH:/usr/bin:/bin:/usr/local/bin

SUDO_MODE="unknown"
SUDO_PW=""

resolve_sudo_mode() {
    if [ "$SUDO_MODE" != "unknown" ]; then
        return 0
    fi

    if sudo -n true >/dev/null 2>&1; then
        SUDO_MODE="nopass"
        log "sudo check: non-interactive sudo is available"
        return 0
    fi

    # UNOQ_CURRENT_PASSWORD is the board's EXISTING password, tried first.
    # UNOQ_DEFAULT_PASSWORD is the password we want the board to end up on,
    # which is also correct once a previous run has already applied it.
    for CANDIDATE in "${UNOQ_CURRENT_PASSWORD:-}" "${UNOQ_DEFAULT_PASSWORD:-}" "arduino"; do
        [ -z "$CANDIDATE" ] && continue
        if printf '%s\n' "$CANDIDATE" | sudo -S -k -p '' true >/dev/null 2>&1; then
            SUDO_MODE="password"
            SUDO_PW="$CANDIDATE"
            if [ "$CANDIDATE" = "arduino" ]; then
                log "sudo check: using fallback sudo password candidate 'arduino'"
            else
                log "sudo check: using configured device password"
            fi
            return 0
        fi
    done

    SUDO_MODE="none"
    log "WARNING: sudo is not available non-interactively; privileged maintenance steps will be skipped."
}

run_sudo_cmd() {
    local cmd="$1"

    resolve_sudo_mode

    if [ "$SUDO_MODE" = "nopass" ]; then
        sudo -n bash -lc "$cmd"
        return $?
    fi

    if [ "$SUDO_MODE" = "password" ]; then
        printf '%s\n' "$SUDO_PW" | sudo -S -k -p '' bash -lc "$cmd"
        return $?
    fi

    return 1
}

run_and_log() {
    local tag="$1"
    shift
    "$@" 2>&1 | while IFS= read -r L; do log "  [$tag] $L"; done
    return ${PIPESTATUS[0]}
}

get_free_mb() {
    local avail_kb
    avail_kb=$(df -Pk / | awk 'NR==2 {print $4}')
    echo $((avail_kb / 1024))
}

cleanup_before_updates() {
    log "Running pre-update cleanup (docker/apt caches) to avoid disk-full failures..."
    local before_mb after_mb
    before_mb=$(get_free_mb)
    log "Free space before cleanup: ${before_mb}MB"

    # Only prune Docker images when space is genuinely short. Pruning on every
    # run deleted App Lab's brick images (Edge Impulse model runner, Python
    # base, ...), which each board then re-downloads over the venue WiFi.
    # Explicit pruning is Step 4 in the web UI (it runs after the update);
    # UNOQ_FORCE_CLEANUP=1 in .env also forces it here. The 1000MB threshold
    # matches the upstream flasher.
    local prune_below_mb=1000
    if [ "$before_mb" -ge "$prune_below_mb" ] && [ "${UNOQ_FORCE_CLEANUP:-0}" != "1" ]; then
        log "${before_mb}MB free (at least ${prune_below_mb}MB), so Docker images are kept. Tick Step 4 to prune them anyway."
    elif command -v docker >/dev/null 2>&1; then
        log "Under ${prune_below_mb}MB free (or UNOQ_FORCE_CLEANUP=1); pruning Docker images to make room."
        run_and_log "docker" docker system df || true
        run_and_log "docker" docker container prune -f || true
        run_and_log "docker" docker image prune -a -f || true
        run_and_log "docker" docker system df || true
    elif command -v podman >/dev/null 2>&1; then
        log "Under ${prune_below_mb}MB free (or UNOQ_FORCE_CLEANUP=1); pruning Podman images to make room."
        run_and_log "podman" podman system df || true
        run_and_log "podman" podman container prune -f || true
        run_and_log "podman" podman image prune -a -f || true
        run_and_log "podman" podman system df || true
    else
        log "No docker/podman runtime found for prune."
    fi

    if resolve_sudo_mode && [ "$SUDO_MODE" != "none" ]; then
        run_and_log "apt" run_sudo_cmd "apt-get clean" || true
        run_and_log "apt" run_sudo_cmd "rm -rf /var/lib/apt/lists/partial/*" || true
    else
        log "Skipping apt cache cleanup (sudo unavailable)."
    fi

    after_mb=$(get_free_mb)
    log "Free space after cleanup: ${after_mb}MB"
}

# ── WiFi ──────────────────────────────────────────────────────────────────────

# On UNO Q the WiFi radio is sometimes soft-blocked (rfkill) and/or disabled in
# NetworkManager after a fresh image boot, so `nmcli dev wifi connect` returns
# "No Wi-Fi device found." even though the hardware is present. Explicitly
# unblock + enable the radio first, then wait for a wifi-type device to appear
# via nmcli (the module can take a while to register — up to a minute on cold
# boots).
log "Unblocking WiFi radio (rfkill) and enabling it via NetworkManager..."
rfkill unblock wifi 2>/dev/null || log "rfkill unblock wifi failed (rfkill may be absent)"
rfkill unblock all 2>/dev/null || true
nmcli radio wifi on 2>/dev/null || log "nmcli radio wifi on failed"

diagnose_wifi() {
    log "--- WiFi diagnostics ---"
    log "rfkill list:"
    rfkill list 2>&1 | while IFS= read -r L; do log "  $L"; done
    log "ip link (wl* interfaces):"
    ip -o link show 2>&1 | grep -E 'wl|wlan' | while IFS= read -r L; do log "  $L"; done
    log "nmcli device status:"
    nmcli device status 2>&1 | while IFS= read -r L; do log "  $L"; done
    log "lsmod wifi-ish modules:"
    lsmod 2>&1 | grep -Ei 'wifi|wlan|brcm|mwifiex|nrc|rtl|iwl' | while IFS= read -r L; do log "  $L"; done
    log "-------------------------"
}

log "Waiting for a WiFi interface to appear (up to 60s)..."
WIFI_DEV_WAIT=60
WIFI_DEV_COUNT=0
WIFI_DEV_READY=0
while [ "$WIFI_DEV_COUNT" -lt "$WIFI_DEV_WAIT" ]; do
    if nmcli -t -f DEVICE,TYPE device 2>/dev/null | grep -q ':wifi$'; then
        log "WiFi interface detected after ${WIFI_DEV_COUNT}s."
        WIFI_DEV_READY=1
        break
    fi
    # Kernel may see a wl* interface even if NetworkManager isn't tracking it
    # yet — poke NM to re-scan its devices in that case.
    if [ $((WIFI_DEV_COUNT % 10)) -eq 5 ] \
        && ip -o link show 2>/dev/null | grep -qE 'wl|wlan'; then
        log "Kernel has a wl* interface but nmcli doesn't; nudging NetworkManager..."
        nmcli general reload 2>/dev/null || true
    fi
    WIFI_DEV_COUNT=$((WIFI_DEV_COUNT + 1))
    sleep 1
done
if [ "$WIFI_DEV_READY" -ne 1 ]; then
    log "WARNING: no WiFi interface after ${WIFI_DEV_WAIT}s. Running diagnostics and attempting NM restart..."
    diagnose_wifi
    if command -v systemctl >/dev/null 2>&1; then
        sudo -n systemctl restart NetworkManager 2>/dev/null \
            && log "NetworkManager restarted; waiting up to 15s for wifi device..." \
            || log "Could not restart NetworkManager (no sudo?)."
        WIFI_DEV_COUNT=0
        while [ "$WIFI_DEV_COUNT" -lt 15 ]; do
            if nmcli -t -f DEVICE,TYPE device 2>/dev/null | grep -q ':wifi$'; then
                log "WiFi interface detected after NM restart (${WIFI_DEV_COUNT}s)."
                WIFI_DEV_READY=1
                break
            fi
            WIFI_DEV_COUNT=$((WIFI_DEV_COUNT + 1))
            sleep 1
        done
    fi
fi
if [ "$WIFI_DEV_READY" -ne 1 ]; then
    log "WARNING: still no WiFi interface. Attempting connect anyway."
fi

# ── WiFi mode ─────────────────────────────────────────────────────────────────
#   connect (default)  join the network now. Needs it in range, and proves the
#                      password works.
#   stage              "save for later": store the network so the board joins
#                      it automatically once it's in range. Works with no AP
#                      present, so it can pre-provision a venue network, but
#                      the password can't be verified until the board sees it.
# The web UI picks this per run and passes it on the command line; a value in
# .env is only a fallback.
WIFI_MODE="${RUN_WIFI_MODE:-${UNOQ_WIFI_MODE:-connect}}"
case "$WIFI_MODE" in
    connect|stage) ;;
    *) log "Unknown WiFi mode '$WIFI_MODE'; using 'connect'."; WIFI_MODE=connect ;;
esac

# Optional extras for a network you can't inspect ahead of time:
#   UNOQ_WIFI_HIDDEN=1       the network doesn't broadcast its name
#   UNOQ_WIFI_KEY_MGMT=sae   WPA3-only network (default wpa-psk = WPA2, which
#                            also joins mixed WPA2/WPA3 networks)

# UUIDs of saved WiFi profiles with this name. `nmcli -t` escapes ':' in names
# as '\:'; a plain `read` (no -r) turns that back into ':'.
wifi_profile_uuids() {
    local want="$1" uuid type name
    nmcli -t -f UUID,TYPE,NAME connection show 2>/dev/null |
    while IFS=: read uuid type name; do
        [ "$type" = "802-11-wireless" ] && [ "$name" = "$want" ] && echo "$uuid"
    done
}

stage_wifi_profile() {
    local ssid="$1" psk="$2" keymgmt="${UNOQ_WIFI_KEY_MGMT:-wpa-psk}"
    local uuids keep extra out rc hidden=no
    [ "${UNOQ_WIFI_HIDDEN:-0}" = "1" ] && hidden=yes

    # nmcli rejects a WPA passphrase outside 8-63 characters. This can't tell
    # us the password is *right*, but it catches typos of that kind now
    # rather than at the venue.
    if [ "${#psk}" -lt 8 ] || [ "${#psk}" -gt 63 ]; then
        add_error "WiFi password must be 8-63 characters (got ${#psk}); network '$ssid' not saved."
        return 1
    fi

    local props=(
        802-11-wireless.ssid "$ssid"
        802-11-wireless.hidden "$hidden"
        wifi-sec.key-mgmt "$keymgmt"
        wifi-sec.psk "$psk"
        connection.autoconnect yes
        ipv4.dns 8.8.8.8
    )

    # Re-runs must not pile up duplicate profiles. Update an existing profile
    # in place rather than delete-and-add: deleting would drop the board off
    # that network if it happens to be the one it's using right now.
    uuids=$(wifi_profile_uuids "$ssid")
    keep=$(printf '%s\n' "$uuids" | sed -n 1p)
    local cmd
    if [ -n "$keep" ]; then
        for extra in $(printf '%s\n' "$uuids" | sed 1d); do
            nmcli connection delete uuid "$extra" >/dev/null 2>&1 \
                && log "  Removed duplicate saved profile for '$ssid'."
        done
        log "Updating saved WiFi network '$ssid' (security: $keymgmt, hidden: $hidden)..."
        cmd=(connection modify uuid "$keep" "${props[@]}")
    else
        log "Saving WiFi network '$ssid' for later (security: $keymgmt, hidden: $hidden)..."
        cmd=(connection add type wifi con-name "$ssid" ifname '*' "${props[@]}")
    fi

    out=$(nmcli "${cmd[@]}" 2>&1); rc=$?
    # nmcli never echoes the passphrase back, so its output is safe to log.
    [ -n "$out" ] && printf '%s\n' "$out" | while IFS= read -r L; do log "  $L"; done

    if [ "$rc" -ne 0 ]; then
        # Saving a system-wide profile can need more privilege than joining.
        log "Saving without sudo failed; retrying with sudo..."
        if resolve_sudo_mode && [ "$SUDO_MODE" != "none" ] \
            && run_sudo_cmd "nmcli $(printf '%q ' "${cmd[@]}")" >/dev/null 2>&1; then
            rc=0
        fi
    fi
    if [ "$rc" -ne 0 ]; then
        add_error "Could not save WiFi network '$ssid': ${out:-permission denied}"
        return 1
    fi

    # Read it back so the log shows what the board will actually use.
    uuids=$(wifi_profile_uuids "$ssid")
    keep=$(printf '%s\n' "$uuids" | sed -n 1p)
    if [ -z "$keep" ]; then
        add_error "WiFi network '$ssid' was not found after saving."
        return 1
    fi
    log "Saved: '$ssid' will be joined automatically when in range (autoconnect=$(nmcli -g connection.autoconnect connection show uuid "$keep" 2>/dev/null))."
    prefer_wifi_profile "$keep" "$ssid"
    return 0
}

# Make the configured network the board's preferred one. With several saved
# networks in range, NetworkManager otherwise picks whichever it used most
# recently, so a board could drift back to an older network (after a reboot,
# say) even though this run configured a new one. Only one network holds the
# raised priority at a time.
PREFERRED_PRIORITY=10
prefer_wifi_profile() {
    local keep="$1" label="$2" uuid type prio
    [ -z "$keep" ] && return 0
    nmcli -t -f UUID,TYPE,AUTOCONNECT-PRIORITY connection show 2>/dev/null |
    while IFS=: read uuid type prio; do
        if [ "$type" = "802-11-wireless" ] && [ "$uuid" != "$keep" ] \
            && [ "$prio" = "$PREFERRED_PRIORITY" ]; then
            nmcli connection modify uuid "$uuid" connection.autoconnect-priority 0 >/dev/null 2>&1
        fi
    done
    if nmcli connection modify uuid "$keep" connection.autoconnect yes \
        connection.autoconnect-priority "$PREFERRED_PRIORITY" >/dev/null 2>&1; then
        log "'$label' is now the preferred WiFi network on this board."
    else
        log "Could not make '$label' the preferred network; the board may still pick another saved network first."
    fi
}

active_wifi_uuid() {
    nmcli -t -f UUID,TYPE connection show --active 2>/dev/null \
        | awk -F: '$2=="802-11-wireless"{print $1; exit}'
}

if [ "$WIFI_MODE" = "stage" ]; then
    log "WiFi mode: SAVE FOR LATER. Not trying to connect now."
    stage_wifi_profile "$UNOQ_WIFI_SSID" "$UNOQ_WIFI_PASSWORD" || true
    NOW_SSID=$(nmcli -t -f active,ssid dev wifi 2>/dev/null | awk -F: '$1=="yes"{print $2; exit}')
    if [ -n "$NOW_SSID" ]; then
        log "Board stays on its current network for now: '$NOW_SSID'."
    else
        log "Board is not on any WiFi network right now."
    fi
    log "The password for '$UNOQ_WIFI_SSID' can't be checked until the board is in range of it."
else
    log "Checking if WiFi is already connected..."
    CURRENT_SSID=$(nmcli -t -f active,ssid dev wifi | grep '^yes:' | cut -d':' -f2)
    if [ "$CURRENT_SSID" = "$UNOQ_WIFI_SSID" ]; then
        log "Already connected to WiFi SSID: $UNOQ_WIFI_SSID"
    else
        log "Rescanning available WiFi networks..."
        nmcli dev wifi rescan 2>/dev/null || true

        log "Connecting to WiFi..."
        wifi_command="nmcli dev wifi connect $UNOQ_WIFI_SSID password $UNOQ_WIFI_PASSWORD"
        log "WiFi command: $wifi_command"

        # Retry budget: up to 15 * 4s = 60s. Covers "radio not up yet", "SSID not
        # seen in the first scan", and slow driver init after a cold boot.
        WIFI_RETRY_MAX=15
        WIFI_RETRY_DELAY=4
        WIFI_ATTEMPT=1
        WIFI_CONNECTED=0

        while [ "$WIFI_ATTEMPT" -le "$WIFI_RETRY_MAX" ]; do
            WIFI_OUTPUT=$(nmcli dev wifi connect "$UNOQ_WIFI_SSID" password "$UNOQ_WIFI_PASSWORD" 2>&1)
            WIFI_EXIT_CODE=$?

            if [ "$WIFI_EXIT_CODE" -eq 0 ]; then
                WIFI_CONNECTED=1
                break
            fi

            if echo "$WIFI_OUTPUT" | grep -Fq "No Wi-Fi device found."; then
                log "No Wi-Fi device found (attempt ${WIFI_ATTEMPT}/${WIFI_RETRY_MAX}); rechecking radio and retrying in ${WIFI_RETRY_DELAY}s..."
                rfkill unblock wifi 2>/dev/null || true
                rfkill unblock all 2>/dev/null || true
                nmcli radio wifi on 2>/dev/null || true
                # Every 5th attempt: dump diagnostics + try a harder recovery.
                if [ "$WIFI_ATTEMPT" -eq 5 ] || [ "$WIFI_ATTEMPT" -eq 10 ]; then
                    diagnose_wifi
                    if command -v systemctl >/dev/null 2>&1; then
                        log "Attempting sudo -n systemctl restart NetworkManager..."
                        sudo -n systemctl restart NetworkManager 2>/dev/null \
                            || log "  (restart failed or no sudo)"
                    fi
                    nmcli general reload 2>/dev/null || true
                fi
                sleep "$WIFI_RETRY_DELAY"
                WIFI_ATTEMPT=$((WIFI_ATTEMPT + 1))
                continue
            fi

            if echo "$WIFI_OUTPUT" | grep -Fq "No network with SSID"; then
                log "SSID '$UNOQ_WIFI_SSID' not seen (attempt ${WIFI_ATTEMPT}/${WIFI_RETRY_MAX}); rescanning and retrying in ${WIFI_RETRY_DELAY}s..."
                nmcli dev wifi rescan 2>/dev/null || true
                sleep "$WIFI_RETRY_DELAY"
                WIFI_ATTEMPT=$((WIFI_ATTEMPT + 1))
                continue
            fi

            add_error "WiFi connection failed: $WIFI_OUTPUT"
            break
        done

        if [ "$WIFI_CONNECTED" -ne 1 ]; then
            if [ "$WIFI_ATTEMPT" -gt "$WIFI_RETRY_MAX" ]; then
                diagnose_wifi
                add_error "WiFi connection failed after ${WIFI_RETRY_MAX} attempts. Last output: $WIFI_OUTPUT"
            fi
            exit 1
        fi
    fi
    prefer_wifi_profile "$(active_wifi_uuid)" "$UNOQ_WIFI_SSID"
fi

# ── DNS ───────────────────────────────────────────────────────────────────────
if [ "$WIFI_MODE" = "stage" ] \
    && ! nmcli -t -f active dev wifi 2>/dev/null | grep -q '^yes'; then
    # Nothing is connected, so there's nothing to tweak or test. The saved
    # network already carries 8.8.8.8 for when the board joins it.
    log "No active WiFi connection; skipping the DNS step."
else
    log "Setting DNS to Google DNS (updates weren't working without this)..."
    CON_NAME=$(nmcli -t -f NAME connection show --active | head -n 1)
    nmcli connection modify "$CON_NAME" ipv4.dns "8.8.8.8"
    nmcli connection up "$CON_NAME"

    log "Testing DNS resolution..."
    nslookup downloads.arduino.cc || log "DNS resolution failed, please check network settings."
fi

# ── WiFi-only early exit ──────────────────────────────────────────────────────
# Everything above this line runs unprivileged: rfkill, `nmcli radio wifi on`,
# `nmcli dev wifi connect` and `nmcli connection modify/up` are all permitted
# to the arduino user via polkit. Everything BELOW needs sudo (apt, system
# update, hostnamectl), which is unavailable on a board whose password is
# still expired. So WiFi-only mode works on a completely fresh board.
if [ "${RUN_WIFI_ONLY:-${UNOQ_WIFI_ONLY:-0}}" = "1" ]; then
    log "WiFi-only mode: skipping internet wait, apt maintenance, system update"
    log "and board naming. WiFi configuration is complete."
    CURRENT_SSID=$(nmcli -t -f active,ssid dev wifi 2>/dev/null \
        | awk -F: '$1=="yes"{print $2; exit}')
    if [ "$WIFI_MODE" = "stage" ]; then
        [ ${#ERRORS[@]} -eq 0 ] && log "Saved for later: '$UNOQ_WIFI_SSID'."
    elif [ -n "$CURRENT_SSID" ]; then
        log "Connected SSID: $CURRENT_SSID"
    else
        log "Not currently associated. Saved profiles:"
        nmcli -t -f NAME,TYPE connection show 2>/dev/null \
            | grep ':802-11-wireless$' | while IFS= read -r L; do log "  ${L%%:*}"; done
    fi
    # print_summary is already wired to `trap ... EXIT`, so don't call it here
    # or it prints twice. Exit non-zero if anything upstream recorded an error.
    if [ ${#ERRORS[@]} -eq 0 ]; then
        exit 0
    fi
    exit 1
fi

# ── Wait for internet ─────────────────────────────────────────────────────────
log "Waiting for internet connectivity (HTTP check)..."
MAX_WAIT=60
COUNT=0
until curl -s --max-time 5 --head https://downloads.arduino.cc > /dev/null 2>&1; do
    COUNT=$((COUNT + 1))
    if [ "$COUNT" -ge "$MAX_WAIT" ]; then
        if [ "$WIFI_MODE" = "stage" ]; then
            add_error "Internet connectivity timeout after ${MAX_WAIT}s. The WiFi network was saved for later, but full setup also needs internet now through some other network. Use 'WiFi only' to just save the network."
        else
            add_error "Internet connectivity timeout after ${MAX_WAIT}s"
        fi
        exit 1
    fi
    log "Not reachable yet, retrying... (${COUNT}/${MAX_WAIT})"
    sleep 1
done
log "Internet connectivity confirmed."

# ── App brick permissions ─────────────────────────────────────────────────────
# Make every .eim model under ArduinoApps executable. Missing files or a missing
# ArduinoApps directory are not errors — many boards / app folders won't have
# any .eim models at all.
log "Setting +x on any .eim models under /home/arduino/ArduinoApps (if any)..."
if [ -d /home/arduino/ArduinoApps ]; then
    EIM_COUNT=0
    EIM_FAILED=0
    while IFS= read -r -d '' EIM_PATH; do
        EIM_COUNT=$((EIM_COUNT + 1))
        if chmod +x "$EIM_PATH" 2>/dev/null; then
            log "chmod +x $EIM_PATH"
        else
            EIM_FAILED=$((EIM_FAILED + 1))
            log "WARN: chmod +x failed for $EIM_PATH (continuing)"
        fi
    done < <(find /home/arduino/ArduinoApps -type f -name '*.eim' -print0 2>/dev/null)
    log "Processed ${EIM_COUNT} .eim file(s); ${EIM_FAILED} chmod failure(s)."
else
    log "No /home/arduino/ArduinoApps directory; skipping .eim permission step."
fi

# ── Remediate broken apt state ────────────────────────────────────────────────
# If a previous run called `arduino-app-cli system update` without
# --only-arduino it can pull in a Debian alsa-ucm-conf (1.2.14-1) that
# conflicts with Arduino's libasound2t64, breaking all future apt operations.
# Detection: the installed alsa-ucm-conf version lacks the Arduino suffix.
cleanup_before_updates

FREE_MB=$(get_free_mb)
if [ "$FREE_MB" -lt 300 ]; then
    add_error "Only ${FREE_MB}MB free on / after cleanup. Need at least 300MB for package index updates."
    exit 1
fi

ALSA_VERSION=$(dpkg-query -W -f='${Version}' alsa-ucm-conf 2>/dev/null || true)
if echo "$ALSA_VERSION" | grep -qE '^1\.2\.14-1$'; then
    log "Detected broken alsa-ucm-conf ($ALSA_VERSION). Running apt remediation..."
    resolve_sudo_mode
    if [ "$SUDO_MODE" = "none" ]; then
        add_error "Cannot run apt remediation: sudo unavailable. Please set UNOQ_DEFAULT_PASSWORD to the board's current sudo password or reflash."
        exit 1
    fi

    run_and_log "dpkg" run_sudo_cmd "dpkg --configure -a" || true
    run_and_log "apt-get update" run_sudo_cmd "apt-get update" || true

    log "  Attempting Arduino-pinned package repair..."
    if ! run_and_log "apt" run_sudo_cmd "apt-get install -y -o Dpkg::Options::=--force-overwrite alsa-ucm-conf=1.2.14-1qcom0.1arduino3 arduino-app-cli arduino-unoq-config arduino-unoq"; then
        log "  Arduino-pinned repair failed; retrying generic repair..."
        run_and_log "apt" run_sudo_cmd "apt-get install -y -o Dpkg::Options::=--force-overwrite arduino-app-cli arduino-unoq-config arduino-unoq" || true
    fi

    log "Remediation complete. Running Arduino-only system update..."
    if ! arduino-app-cli system update --yes --only-arduino; then
        add_error "arduino-app-cli system update (remediation) failed"
    fi
else
    log "apt state looks healthy (alsa-ucm-conf=${ALSA_VERSION:-not installed})."
fi

# ── System update ─────────────────────────────────────────────────────────────
log "Running arduino-app-cli system update..."
if ! arduino-app-cli system update --yes --only-arduino; then
   add_error "arduino-app-cli system update failed"
fi
# ── Board name ────────────────────────────────────────────────────────────────
# App Lab's "name your board" step just sets the system hostname. From
# arduino-app-cli pkg/board/board.go:
#     SetCustomName -> sudo hostnamectl set-hostname <name>, then restarts
#                      avahi-daemon so mDNS advertises the new name
#     GetCustomName -> reads /etc/hostname
# and it validates against ^[a-zA-Z0-9][a-zA-Z0-9-]{0,63}$.
#
# Set UNOQ_BOARD_NAME in .env:
#   (unset)  leave the hostname alone
#   random   generate a friendly random name, e.g. amber-heron-3f9c
#   <name>   use that name verbatim (must match the regex above)

BOARD_NAME_RE='^[a-zA-Z0-9][a-zA-Z0-9-]{0,63}$'

rand_below() {
    # Uniform-ish index in [0,$1) seeded from /dev/urandom, not $RANDOM,
    # so boards flashed in the same second don't collide.
    local n
    n=$(od -An -N2 -tu2 < /dev/urandom 2>/dev/null | tr -d ' ')
    [ -z "$n" ] && n=$$
    echo $(( n % $1 ))
}

generate_board_name() {
    # Deliberately bland, unambiguous words: nothing that reads badly when
    # combined, nothing that could be a slur, initialism or innuendo.
    local ADJ=(amber azure brave breezy bright calm cedar cheery clever cosmic
               crisp gentle jolly keen lively lucky merry mellow noble quiet
               rapid shiny silver sturdy sunny swift teal tidy witty zesty)
    local NOUN=(acorn anchor beacon birch canyon cedar comet delta dune ember
                falcon fern harbor heron island lantern meadow nimbus orchid
                otter pebble quartz ridge river sparrow summit thicket valley
                willow wren)
    local a n sfx
    a=${ADJ[$(rand_below ${#ADJ[@]})]}
    n=${NOUN[$(rand_below ${#NOUN[@]})]}
    sfx=$(od -An -N2 -tx1 < /dev/urandom 2>/dev/null | tr -d ' \n')
    [ -z "$sfx" ] && sfx=$$
    printf '%s-%s-%s' "$a" "$n" "$sfx"
}

apply_board_name() {
    local name="$1" old
    if ! printf '%s' "$name" | grep -qE "$BOARD_NAME_RE"; then
        add_error "Board name '$name' is invalid. App Lab requires ${BOARD_NAME_RE}."
        return 1
    fi

    old=$(cat /etc/hostname 2>/dev/null | tr -d '[:space:]')
    if [ "$old" = "$name" ]; then
        log "Board name is already '$name'; nothing to do."
        return 0
    fi

    if ! resolve_sudo_mode || [ "$SUDO_MODE" = "none" ]; then
        add_error "Cannot set board name: sudo unavailable."
        return 1
    fi

    if ! run_sudo_cmd "hostnamectl set-hostname '$name'"; then
        add_error "hostnamectl set-hostname '$name' failed."
        return 1
    fi

    # Keep /etc/hosts in step, or every later sudo prints
    # "unable to resolve host <name>" and stalls on the lookup.
    run_sudo_cmd "if grep -q '^127.0.1.1' /etc/hosts; then \
sed -i 's/^127\.0\.1\.1.*/127.0.1.1\t$name/' /etc/hosts; else \
printf '127.0.1.1\t%s\n' '$name' >> /etc/hosts; fi" \
        || log "  (could not update /etc/hosts; harmless but sudo may warn)"

    # Restart avahi so the NETWORK entry shows the new name too. Without this
    # App Lab shows the custom name over USB but still 'uno-q' over the network.
    run_sudo_cmd "systemctl restart avahi-daemon" \
        || log "  (avahi restart failed; network name updates after next reboot)"

    log "Board name set to '$name' (was '${old:-unset}')."
    return 0
}

if [ -z "${UNOQ_BOARD_NAME:-}" ]; then
    log "UNOQ_BOARD_NAME not set; leaving board name unchanged."
elif [ "${UNOQ_BOARD_NAME}" = "random" ]; then
    NEW_BOARD_NAME=$(generate_board_name)
    log "Assigning random board name: $NEW_BOARD_NAME"
    apply_board_name "$NEW_BOARD_NAME" || true
else
    log "Setting board name from UNOQ_BOARD_NAME: ${UNOQ_BOARD_NAME}"
    apply_board_name "${UNOQ_BOARD_NAME}" || true
fi
