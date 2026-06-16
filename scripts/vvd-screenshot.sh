#!/usr/bin/env bash
# Capture a screenshot from a running VVD via the emulator console (the
# gfxstream readback path — the only one that is non-black; see
# docs/vvd-screen-capture.md). Requires the VVD to have been started with
# -gpu host (scripts/start-vvd.sh).
#
#   scripts/vvd-screenshot.sh /out/shot.png      # console port defaults to 5554
#   VVD_CONSOLE_PORT=5556 scripts/vvd-screenshot.sh /out/shot.png
set -euo pipefail

OUT="${1:?usage: vvd-screenshot.sh <output.png>}"
PORT="${VVD_CONSOLE_PORT:-5554}"
TOKEN_FILE="${HOME}/.emulator_console_auth_token"

tmpdir="$(mktemp -d)"
python3 - "$PORT" "$TOKEN_FILE" "$tmpdir" <<'PY'
import socket, sys, time
port, token_file, outdir = int(sys.argv[1]), sys.argv[2], sys.argv[3]
tok = open(token_file).read().strip()
s = socket.create_connection(("127.0.0.1", port)); s.settimeout(10)
def rd():
    time.sleep(0.5)
    try: return s.recv(65536).decode(errors="replace")
    except Exception: return ""
rd()
s.sendall(("auth %s\n" % tok).encode()); rd()
s.sendall(("screenrecord screenshot %s\n" % outdir).encode())
print(rd().strip()[:40]); s.sendall(b"quit\n")
PY

shot="$(ls -t "$tmpdir"/Screenshot_*.png 2>/dev/null | head -1 || true)"
[[ -z "$shot" ]] && { echo "ERROR: no screenshot produced" >&2; exit 1; }
mv "$shot" "$OUT"; rmdir "$tmpdir" 2>/dev/null || true
echo "saved $OUT ($(stat -c%s "$OUT") bytes)"
