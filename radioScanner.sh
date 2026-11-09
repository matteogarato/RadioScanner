#!/bin/bash
#
# SDR airband recorder + Whisper transcriber (Ubuntu / Debian)
#
# Usage:
#   ./sdr_airband_transcriber.sh               check/install requirements, then record
#   ./sdr_airband_transcriber.sh --setup-only  only check/install requirements
#   ./sdr_airband_transcriber.sh --skip-setup  record without the setup checks
#
# Output: one WAV per transmission in sdr_registrazioni_aeree/, plus a .txt with
# the same base name containing the transcription.

set -Eeuo pipefail
trap 'echo "ERROR: script failed at line $LINENO" >&2' ERR

# ============================================================
# CONFIGURATION
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REC_DIR="$SCRIPT_DIR/sdr_registrazioni_aeree"
VENV="$SCRIPT_DIR/whisper-env"
WORKER="$SCRIPT_DIR/sdr_transcriber.py"
LOG="$REC_DIR/trascrizioni.log"

# Whisper settings
WHISPER_MODEL="base"        # tiny | base | small | medium (base: far less RAM than small, slightly less accurate)
WHISPER_LANG="en"           # en | it | "" for automatic detection
CPU_THREADS=2               # Whisper CPU threads: fewer = less CPU load, slower transcription (0 = library default)

# SDR settings
SAMPLE_RATE=16000
GAIN=42
DC_BLOCK=1                  # 1 = enable rtl_fm DC blocking filter (recommended for AM)

# ------------------------------------------------------------
# SQUELCH AND TRANSMISSION DETECTION
# All noise-gating settings live here: this is the single place to tune them.
# ------------------------------------------------------------
SQUELCH=35                  # rtl_fm hardware squelch (-l); must be > 0 when scanning several
                            #   frequencies. Higher = ignores weaker signals.
VOICE_RMS=50                # software voice gate on the audio. Raise if noise gets recorded,
                            #   lower if quiet speech is missed.
GAP_SECONDS=1.5             # no voice for this long = transmission ended
MIN_SECONDS=1.0             # discard recordings shorter than this
MAX_SECONDS=120             # safety cap for a single recording
DELETE_NO_SPEECH=1          # 1 = delete the WAV when Whisper finds no speech in it

# Frequencies in Hz
FREQUENCIES=(
    120200000
    121700000
    118900000
    122225000
    120725000
    124150000
    123250000
)

# ============================================================
# HELPERS
# ============================================================

info() { echo "[setup] $*"; }
warn() { echo "[setup] WARNING: $*" >&2; }
fail() { echo "[setup] ERROR: $*" >&2; exit 1; }

SUDO=""

# ============================================================
# SETUP: CHECK AND INSTALL REQUIREMENTS
# ============================================================

check_dongle() {

    info "Testing the RTL-SDR dongle (rtl_test)..."

    local out
    out=$(timeout 10 rtl_test -t 2>&1 || true)

    if grep -q "No supported devices found" <<<"$out"; then
        fail "No RTL-SDR dongle detected. Plug it in (try another USB port) and run again."
    fi

    if grep -q "Failed to open rtlsdr device" <<<"$out"; then

        if grep -q "usb_open error -3" <<<"$out"; then

            warn "USB permission problem."

            if [ "$(id -u)" -ne 0 ] && getent group plugdev >/dev/null 2>&1; then
                case " $(id -nG) " in
                    *" plugdev "*) ;;
                    *)
                        info "Adding $(id -un) to the 'plugdev' group..."
                        $SUDO usermod -aG plugdev "$(id -un)"
                        ;;
                esac
            fi

            fail "Unplug and replug the dongle, then log out and back in (or reboot) and run again."
        fi

        fail "The dongle is busy or cannot be opened. Close other SDR programs, unplug/replug it (or reboot if the DVB-T driver was just blacklisted) and run again."
    fi

    if grep -q "Found .* tuner" <<<"$out"; then
        info "Dongle OK: $(grep -m1 'Found .* tuner' <<<"$out")"
    else
        warn "Could not confirm the dongle state. rtl_test output:"
        echo "$out" >&2
    fi
}

setup() {

    echo "=== Setup: checking requirements ==="

    command -v apt-get >/dev/null 2>&1 \
        || fail "apt-get not found: this setup supports Ubuntu/Debian only."

    if [ "$(id -u)" -ne 0 ]; then
        command -v sudo >/dev/null 2>&1 || fail "sudo is required to install packages."
        SUDO="sudo"
    fi

    # ---- System packages -----------------------------------------------

    local pkgs=()

    command -v python3 >/dev/null 2>&1 || pkgs+=(python3)
    python3 -c "import venv, ensurepip" >/dev/null 2>&1 || pkgs+=(python3-venv)

    if ! command -v rtl_fm >/dev/null 2>&1 || ! command -v rtl_test >/dev/null 2>&1; then
        pkgs+=(rtl-sdr)
    fi

    command -v lsusb >/dev/null 2>&1 || pkgs+=(usbutils)

    if [ ${#pkgs[@]} -gt 0 ]; then
        info "Installing missing system packages: ${pkgs[*]}"
        $SUDO apt-get update
        $SUDO apt-get install -y "${pkgs[@]}"
    else
        info "System packages: OK"
    fi

    command -v rtl_fm   >/dev/null 2>&1 || fail "rtl_fm is still missing after installation."
    command -v rtl_test >/dev/null 2>&1 || fail "rtl_test is still missing after installation."
    command -v python3  >/dev/null 2>&1 || fail "python3 is still missing after installation."

    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' \
        || fail "Python 3.9 or newer is required (found $(python3 --version 2>&1))."

    # ---- DVB-T kernel driver (steals the dongle from rtl_fm) ----------

    if ! grep -qsR "^[[:space:]]*blacklist[[:space:]]\+dvb_usb_rtl28xxu" \
            /etc/modprobe.d /lib/modprobe.d /usr/lib/modprobe.d 2>/dev/null; then
        info "Blacklisting the DVB-T kernel driver so it does not block the dongle..."
        printf 'blacklist dvb_usb_rtl28xxu\nblacklist rtl2832\nblacklist rtl2830\n' \
            | $SUDO tee /etc/modprobe.d/blacklist-rtl-sdr.conf >/dev/null
    else
        info "DVB-T driver blacklist: OK"
    fi

    if grep -q '^dvb_usb_rtl28xxu ' /proc/modules; then
        info "Unloading the running DVB-T driver..."
        $SUDO rmmod dvb_usb_rtl28xxu 2>/dev/null \
            || warn "Could not unload it now. Unplug/replug the dongle or reboot."
    fi

    # ---- Python environment --------------------------------------------

    if [ -d "$VENV" ]; then
        if ! "$VENV/bin/python" -c "import sys" >/dev/null 2>&1; then
            info "Repairing Python virtual environment..."
            python3 -m venv --upgrade "$VENV"
        fi
    else
        info "Creating Python virtual environment..."
        python3 -m venv "$VENV"
    fi

    if ! "$VENV/bin/python" -c "import faster_whisper, numpy" >/dev/null 2>&1; then
        info "Installing faster-whisper and numpy (this can take a few minutes)..."
        "$VENV/bin/python" -m pip install --upgrade pip
        "$VENV/bin/python" -m pip install --upgrade faster-whisper numpy "av<19"
    else
        info "Python packages: OK"
    fi

    # PyAV 19 (released 2026-09-29) removed an argument that faster-whisper 1.2.x still
    # passes, which breaks every transcription with:
    #   open() got an unexpected keyword argument 'metadata_errors'
    # Keep PyAV below 19 until faster-whisper supports it.
    if ! "$VENV/bin/python" -c 'import sys, av; sys.exit(0 if int(av.__version__.split(".")[0]) < 19 else 1)' >/dev/null 2>&1; then
        info "Pinning PyAV below 19 (compatibility with faster-whisper)..."
        "$VENV/bin/python" -m pip install "av<19"
    fi

    # ---- Whisper model (downloaded once, then cached) ------------------

    local marker="$VENV/.model_${WHISPER_MODEL}.ok"

    if [ ! -f "$marker" ]; then
        info "Downloading/loading Whisper model '$WHISPER_MODEL' (internet needed the first time)..."
        "$VENV/bin/python" -c '
import sys
from faster_whisper import WhisperModel
WhisperModel(sys.argv[1], device="cpu", compute_type="int8")
' "$WHISPER_MODEL" || fail "Could not load the Whisper model. Check your internet connection."
        touch "$marker"
    else
        info "Whisper model '$WHISPER_MODEL': OK"
    fi

    # ---- Output folder and disk space ----------------------------------

    mkdir -p "$REC_DIR"

    local avail_mb
    avail_mb=$(df -Pm "$REC_DIR" | awk 'NR==2 {print $4}')

    if [ "${avail_mb:-0}" -lt 2000 ]; then
        warn "Less than 2 GB free in $REC_DIR (${avail_mb} MB). Recordings are about 2 MB per minute of speech."
    fi

    # ---- Dongle ---------------------------------------------------------

    check_dongle

    echo "=== Setup complete ==="
}

# ============================================================
# PYTHON RECORDER + TRANSCRIPTION WORKER
# ============================================================

write_worker() {

cat > "$WORKER" <<'PYEOF'
import argparse
import logging
import os
import queue
import select
import signal
import subprocess
import sys
import threading
import time
import wave
from datetime import datetime

import numpy as np
from faster_whisper import WhisperModel


# ============================================================
# ARGUMENTS
# ============================================================

parser = argparse.ArgumentParser()

parser.add_argument("--record-dir", required=True)
parser.add_argument("--log", required=True)
parser.add_argument("--model", default="small")
parser.add_argument("--language", default="en")
parser.add_argument("--cpu-threads", type=int, default=0)
# Values come from the bash configuration block (single source of truth).
parser.add_argument("--sample-rate", type=int, required=True)
parser.add_argument("--max-seconds", type=int, required=True)
parser.add_argument("--min-seconds", type=float, required=True)
parser.add_argument("--gap-seconds", type=float, required=True)
parser.add_argument("--voice-rms", type=float, required=True)
parser.add_argument("--gain", type=int, required=True)
parser.add_argument("--squelch", type=int, required=True)
parser.add_argument("--dc-block", action="store_true")
parser.add_argument("--delete-no-speech", action="store_true")
parser.add_argument("--frequencies", nargs="+", type=int, required=True)

args = parser.parse_args()

os.makedirs(args.record_dir, exist_ok=True)

BYTES_PER_SECOND = args.sample_rate * 2
MIN_BYTES = int(args.min_seconds * BYTES_PER_SECOND)
MAX_BYTES = int(args.max_seconds * BYTES_PER_SECOND)


# ============================================================
# LOGGING
# ============================================================

logging.basicConfig(
    filename=args.log,
    level=logging.INFO,
    format="%(asctime)s %(message)s",
)


def log(message):
    print(message, flush=True)
    logging.info(message)


# ============================================================
# WHISPER
# ============================================================

log("Loading faster-whisper model: " + args.model)

model = WhisperModel(
    args.model,
    device="cpu",
    compute_type="int8",
    cpu_threads=args.cpu_threads,
    num_workers=1,
)

log("Whisper model ready.")

jobs = queue.Queue()


def delete_audio(path):

    try:
        os.remove(path)
        log("NO SPEECH: deleted " + os.path.basename(path))
        return True
    except OSError as e:
        log("Could not delete " + os.path.basename(path) + ": " + str(e))
        return False


def transcription_worker():

    while True:

        audio_path = jobs.get()

        try:

            if audio_path is None:
                return

            text_path = os.path.splitext(audio_path)[0] + ".txt"

            log("Transcribing: " + os.path.basename(audio_path))

            try:

                segments, _info = model.transcribe(
                    audio_path,
                    language=args.language or None,
                    beam_size=1,
                    vad_filter=True,
                    condition_on_previous_text=False,
                    initial_prompt=(
                        "Air traffic control, Venice, Padua, "
                        "runway, cleared, QNH, squawk."
                    ),
                )

                text = " ".join(s.text.strip() for s in segments).strip()

                if not text:

                    # No speech: drop the audio and do not create a .txt.
                    if args.delete_no_speech and delete_audio(audio_path):
                        continue

                    text = "(No speech detected)"

                with open(text_path, "w", encoding="utf-8") as f:
                    f.write(text + "\n")

                log("TRANSCRIBED: " + os.path.basename(text_path) + " -> " + text)

            except Exception as e:

                error = "[TRANSCRIPTION ERROR] " + str(e)

                with open(text_path, "w", encoding="utf-8") as f:
                    f.write(error + "\n")

                log(error)

        finally:
            jobs.task_done()


worker_thread = threading.Thread(target=transcription_worker, daemon=False)
worker_thread.start()


# ============================================================
# SDR COMMAND
# ============================================================

rtl_command = ["rtl_fm"]

for frequency in args.frequencies:
    rtl_command.extend(["-f", str(frequency)])

rtl_command.extend([
    "-M", "am",
    "-s", str(args.sample_rate),
    "-g", str(args.gain),
    "-l", str(args.squelch),
])

if args.dc_block:
    rtl_command.extend(["-E", "dc"])

log("Starting RTL-SDR scanner...")
log("Frequencies: " + ", ".join(map(str, args.frequencies)))
log("Command: " + " ".join(rtl_command))


# ============================================================
# SIGNALS
# ============================================================

process = None
stop_requested = False


def handle_signal(signum, frame):

    global stop_requested

    # A second signal forces an immediate exit (skips pending transcriptions).
    if stop_requested:
        os.write(2, b"Second signal received: forcing exit.\n")
        os._exit(1)

    stop_requested = True

    if process is not None and process.poll() is None:
        process.terminate()


signal.signal(signal.SIGINT, handle_signal)
signal.signal(signal.SIGTERM, handle_signal)


# ============================================================
# SAVE WAV FILE
# ============================================================

def save_recording(audio_data):

    # Keep only complete 16-bit samples.
    if len(audio_data) % 2:
        audio_data = audio_data[:-1]

    if not audio_data:
        return

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S_%f")
    filename = "atc_" + timestamp + ".wav"
    audio_path = os.path.join(args.record_dir, filename)

    try:

        with wave.open(audio_path, "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(args.sample_rate)
            wav.writeframes(audio_data)

        log("RECORDED: %s (%.1f s)" % (filename, len(audio_data) / BYTES_PER_SECOND))

        # Queue only after the WAV file is completely closed.
        jobs.put(audio_path)

    except Exception as e:
        log("RECORDING ERROR: " + str(e))


def flush(buf):

    if len(buf) >= MIN_BYTES:
        save_recording(bytes(buf))

    buf.clear()


def is_voice(raw):

    x = np.frombuffer(raw, dtype=np.int16).astype(np.float32)
    x -= x.mean()                      # ignore DC offset from AM demodulation

    return float(np.sqrt(np.mean(x * x))) > args.voice_rms


# ============================================================
# RECORD ONE FILE PER TRANSMISSION
# ============================================================
#
# rtl_fm may either stop emitting audio while the squelch is closed or
# emit silence. Both cases are handled: a transmission ends when there has
# been no voice for --gap-seconds (select() timeouts cover the first case,
# the RMS check covers the second).

exit_code = 0

try:

    if not stop_requested:

        process = subprocess.Popen(rtl_command, stdout=subprocess.PIPE, bufsize=0)

        fd = process.stdout.fileno()

        log("RTL-SDR started. Recording and transcription are running.")

        buffer = bytearray()
        carry = b""
        last_voice = 0.0

        while True:

            ready, _, _ = select.select([fd], [], [], 0.25)

            if ready:

                data = os.read(fd, 8192)

                if not data:
                    break

                data = carry + data
                carry = data[-1:] if len(data) % 2 else b""
                data = data[:len(data) - len(carry)]

                if data:

                    voice = is_voice(data)

                    if voice:
                        last_voice = time.monotonic()

                    # Start on voice; once started, keep the trailing audio.
                    if voice or buffer:
                        buffer.extend(data)

            # Runs on every loop, including select timeouts.
            if buffer and (
                time.monotonic() - last_voice > args.gap_seconds
                or len(buffer) >= MAX_BYTES
            ):
                flush(buffer)

        if buffer:
            log("Saving final recording...")
            flush(buffer)

except Exception as e:

    log("FATAL ERROR: " + str(e))
    exit_code = 1

finally:

    if stop_requested:
        log("Shutdown requested...")

    if process is not None:

        if process.poll() is None:
            process.terminate()

        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()

        if process.stdout:
            process.stdout.close()

        if not stop_requested:
            log(
                "rtl_fm exited unexpectedly (code %s). Check that the dongle is "
                "connected, not in use by another program, and that you have "
                "USB permissions." % process.returncode
            )
            exit_code = 1

    log("Waiting for pending transcriptions (press CTRL+C again to force exit)...")

    jobs.join()
    jobs.put(None)
    worker_thread.join()

    log("SDR recorder stopped.")

sys.exit(exit_code)
PYEOF

}

# ============================================================
# MAIN
# ============================================================

MODE="${1:-run}"

case "$MODE" in
    run)
        setup
        ;;
    --setup-only)
        setup
        exit 0
        ;;
    --skip-setup)
        ;;
    *)
        echo "Usage: $0 [--setup-only | --skip-setup]" >&2
        exit 1
        ;;
esac

if [ ${#FREQUENCIES[@]} -gt 1 ] && [ "$SQUELCH" -le 0 ]; then
    fail "SQUELCH must be greater than 0 when scanning several frequencies (rtl_fm only hops when the squelch closes)."
fi

if [ ! -x "$VENV/bin/python" ]; then
    fail "Python environment not found. Run without --skip-setup first."
fi

mkdir -p "$REC_DIR"
write_worker

EXTRA_ARGS=()
if [ "$DC_BLOCK" = "1" ]; then
    EXTRA_ARGS+=(--dc-block)
fi
if [ "$DELETE_NO_SPEECH" = "1" ]; then
    EXTRA_ARGS+=(--delete-no-speech)
fi

echo ""
echo "=============================================="
echo "       SDR AIRBAND RECORDING SYSTEM"
echo "=============================================="
echo "Recording directory: $REC_DIR"
echo "Whisper model:       $WHISPER_MODEL"
echo "Language:            ${WHISPER_LANG:-Automatic}"
echo "Sample rate:         $SAMPLE_RATE Hz"
echo ""
echo "Frequencies:"
for FREQ in "${FREQUENCIES[@]}"; do
    echo "  $FREQ Hz"
done
echo ""
echo "Press CTRL+C to stop."
echo "=============================================="

if ! "$VENV/bin/python" "$WORKER" \
        --record-dir "$REC_DIR" \
        --log "$LOG" \
        --model "$WHISPER_MODEL" \
        --language "$WHISPER_LANG" \
        --cpu-threads "$CPU_THREADS" \
        --sample-rate "$SAMPLE_RATE" \
        --max-seconds "$MAX_SECONDS" \
        --min-seconds "$MIN_SECONDS" \
        --gap-seconds "$GAP_SECONDS" \
        --voice-rms "$VOICE_RMS" \
        --gain "$GAIN" \
        --squelch "$SQUELCH" \
        "${EXTRA_ARGS[@]}" \
        --frequencies "${FREQUENCIES[@]}"; then
    echo ""
    echo "The recorder stopped with an error. See $LOG for details." >&2
    exit 1
fi

echo ""
echo "Recording and transcription completed."
