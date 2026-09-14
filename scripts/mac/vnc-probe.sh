#!/bin/bash
# vnc-probe.sh — diagnosa "black screen" noVNC + macOS Screen Sharing.
#
# Menjawab pertanyaan penentu:
#   A) Apakah DESKTOP (framebuffer GUI `runner`) benar-benar hitam?
#      (virtual display tidak render / layar mati / TCC) 
#   B) Apakah STREAM VNC dari screensharingd berisi pixel nyata?
#      (menyingkirkan bug noVNC vs layar yang memang hitam)
#
# Output (format grep-able):
#   DISPLAY_*         — info virtual display (system_profiler)
#   DESKTOP=HITAM|HIDUP          — dari screencapture sesi GUI
#   VNC_SERVER=WxH name          — resolusi + nama sesi dari screensharingd
#   VNC_STREAM=BLACK|NONBLACK|SKIP — dari probe VNC native (type 2 / VNC DES)
#
# Menjalankan probe ini TIDAK pernah menggagalkan workflow: semua yang
# mungkin gagal dibungkus dengan toleransi. `set -u` (bukan -e).

set -u

C_RED='\033[1;31m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'
C_CYAN='\033[1;36m'; C_BOLD='\033[1m'; C_NC='\033[0m'

VNC_PASSWORD="${VNC_PASSWORD:-}"
GUID_USER="${GUID_USER:-runner}"
if ! id -u "$GUID_USER" >/dev/null 2>&1; then GUID_USER="$(id -un || echo runner)"; fi
GUID_UID="$(id -u "$GUID_USER" 2>/dev/null || id -u)"

echo ""
echo "=============================================================="
echo -e "${C_BOLD}[vnc-probe]${C_NC} Diagnosa black screen — desktop vs VNC stream"
echo "=============================================================="

# ============================================================
# 1) DISPLAY INFO
# ============================================================
echo ""
echo -e "${C_CYAN}[1/3] Info virtual display${C_NC}"
if command -v system_profiler >/dev/null 2>&1; then
  system_profiler SPDisplaysDataType 2>/dev/null | grep -Ei 'Chipset|Type:|Resolution:|Online:|UI Looks Like|Main Display|Retina' | head -12 || echo "  (SPDisplaysDataType tidak menghasilkan data)"
else
  echo "  (system_profiler tidak tersedia)"
fi

# ============================================================
# 2) DESKTOP PROBE — screencapture sesi GUI
# ============================================================
echo ""
echo -e "${C_CYAN}[2/3] Probe desktop (screencapture sesi GUI '${GUID_USER}' uid=${GUID_UID})${C_NC}"
DESKTOP_PNG="/tmp/vnc-probe-desktop.png"
rm -f "$DESKTOP_PNG"
launchctl asuser "$GUID_UID" /usr/sbin/screencapture -x "$DESKTOP_PNG" >/dev/null 2>&1 \
  || sudo -u "$GUID_USER" /usr/sbin/screencapture -x "$DESKTOP_PNG" >/dev/null 2>&1

if [ -s "$DESKTOP_PNG" ]; then
  read -r PX NZR < <(python3 - "$DESKTOP_PNG" <<'PYEOF' 2>/dev/null || echo "0 0"
import sys, zlib, struct
data = open(sys.argv[1], 'rb').read()
if data[:8] != b'\x89PNG\r\n\x1a\n':
    print("0 0"); sys.exit(0)
pos = 8; idat = b''
while pos < len(data):
    ln = struct.unpack('>I', data[pos:pos+4])[0]
    typ = data[pos+4:pos+8]
    body = data[pos+8:pos+8+ln]
    pos += 12 + ln
    if typ == b'IDAT':
        idat += body
try:
    px = zlib.decompress(idat)
except Exception:
    print("0 0"); sys.exit(0)
nz = sum(1 for b in px if b != 0)
print("%d %d" % (len(px), nz))
PYEOF
)
  if [ "$PX" -gt 0 ] && [ "$NZR" -gt 0 ]; then
    RATIO=$(awk "BEGIN{printf \"%.4f\", $NZR/$PX}")
    if awk "BEGIN{exit !($RATIO > 0.002)}"; then
      echo -e "${C_GREEN}[OK] DESKTOP=HIDUP — screenshot ${C_BOLD}$(basename "$DESKTOP_PNG")${C_NC} px=$PX non_zero_ratio=$RATIO${C_NC}"
    else
      echo -e "${C_RED}[HITAM] DESKTOP=HITAM — screenshot nyaris semua 0 px=$PX non_zero_ratio=$RATIO${C_NC}"
    fi
  else
    echo -e "${C_YELLOW}[INFO] screencapture menghasilkan file tapi tidak ter-decode (filestatus). Ukuran: $(stat -f '%z' "$DESKTOP_PNG" 2>/dev/null || echo '?') bytes${C_NC}"
    if [ "$(stat -f '%z' "$DESKTOP_PNG" 2>/dev/null || echo 0)" -lt 3000 ]; then
      echo -e "${C_RED}      Ukuran file sangat kecil (<3KB) — kemungkinan layar HITAM/statis.${C_NC}"
    else
      echo -e "${C_GREEN}      Ukuran file besar (>3KB) — kemungkinan desktop HIDUP (ada konten).${C_NC}"
    fi
  fi
else
  echo -e "${C_YELLOW}[INFO] screencapture gagal / file kosong — sesi GUI tidak tangkap (lihat step Verify/Diagnostic).${C_NC}"
fi

# ============================================================
# 3) VNC STREAM PROBE — handshake RFB 3.8 + auth type 2 + framebuffer
# ============================================================
echo ""
echo -e "${C_CYAN}[3/3] Probe stream VNC native (auth type 2, sama seperti noVNC)${C_NC}"

if [ -z "$VNC_PASSWORD" ]; then
  echo -e "${C_YELLOW}[INFO] VNC_STREAM=SKIP — VNC_PASSWORD kosong.${C_NC}"
elif ! python3 -c "import Crypto.Cipher.DES" >/dev/null 2>&1; then
  echo -e "${C_YELLOW}[INFO] Memasang pycryptodome (DES) untuk probe VNC ...${C_NC}"
  pip3 install --quiet --disable-pip-version-check pycryptodome >/dev/null 2>&1 || true
fi
if python3 -c "import Crypto.Cipher.DES" >/dev/null 2>&1; then
  if nc -z -G 2 127.0.0.1 5900 >/dev/null 2>&1; then
    VNC_PROBE_PASSWORD="$VNC_PASSWORD" python3 - <<'PYEOF'
import os, socket, struct, sys

password = os.environ.get("VNC_PROBE_PASSWORD", "").encode('utf-8')

def rq(s, n):
    buf = b""
    while len(buf) < n:
        c = s.recv(n - len(buf))
        if not c:
            raise EOFError("koneksi ditutup server")
        buf += c
    return buf

try:
    s = socket.create_connection(("127.0.0.1", 5900), timeout=15)
    s.settimeout(20)
except Exception as e:
    print("VNC_STREAM=SKIP connect_error=%r" % e)
    sys.exit(0)

try:
    # --- handshake versi RFB ---
    s.sendall(b"RFB 003.008\n")
    banner = rq(s, 12)
    print("VNC_BANNER=%s" % banner.decode(errors='replace').strip())
    if b"RFB" not in banner:
        print("VNC_STREAM=NO_RFB_BANNER")
        sys.exit(0)

    # --- security types ---
    nt = rq(s, 1)[0]
    types = rq(s, nt)
    print("VNC_SECTYPES=%s" % ",".join(map(str, types)))
    if 2 not in types:
        print("VNC_STREAM=NO_TYPE2")
        sys.exit(0)

    # --- auth type 2 (VNC DES), replikasi noVNC genDES: DES-ECB, key = raw password ---
    s.sendall(b"\x02")
    challenge = rq(s, 16)
    key = (password[:8] + b"\x00" * 8)[:8]
    from Crypto.Cipher import DES
    resp = DES.new(key, DES.MODE_ECB).encrypt(challenge)
    s.sendall(resp)
    result = struct.unpack(">I", rq(s, 4))[0]
    if result != 0:
        print("VNC_STREAM=AUTH_FAILED")
        sys.exit(0)
    print("VNC_AUTH=SUCCESS")

    # --- client init (shared) + server init ---
    s.sendall(b"\x01")
    w, h = struct.unpack(">HH", rq(s, 4))
    rq(s, 16)                     # pixel format server
    name_len = struct.unpack(">I", rq(s, 4))[0]
    name = rq(s, name_len)
    print("VNC_SERVER=%dx%d name=%r" % (w, h, name.decode(errors='replace')))
    if w == 0 or h == 0:
        print("VNC_STREAM=ZERO_DISPLAY_%dx%d" % (w, h))
        sys.exit(0)

    # --- paksa encoding Raw saja ---
    s.sendall(b"\x02\x00\x00\x01")          # SetEncodings, count=1
    s.sendall(struct.pack(">i", 0))          # Raw
    # --- set pixel format: 32bpp truecolor big-endian ---
    msg = b"\x00" + b"\x00\x00\x00"          # SetPixelFormat + padding
    msg += struct.pack(">H", 32)             # bpp
    msg += struct.pack(">H", 24)             # depth
    msg += struct.pack(">H", 1)              # big-endian
    msg += struct.pack(">H", 1)              # true-color
    msg += struct.pack(">H", 255) * 3        # red/green/blue max
    msg += bytes([16, 8, 0])                 # shifts
    msg += b"\x00\x00\x00"                   # padding
    s.sendall(msg)
    # --- request FramebufferUpdate NON-incremental (paksa kirim layar penuh) ---
    s.sendall(b"\x03\x00")                   # type 3, no incremental
    s.sendall(struct.pack(">HHHH", 0, 0, w, h))

    mtype = rq(s, 1)[0]
    rq(s, 1)                                 # padding
    if mtype != 0:
        print("VNC_STREAM=UNEXPECTED_MSG_%d" % mtype)
        sys.exit(0)
    nrect = struct.unpack(">H", rq(s, 2))[0]
    total_bright = 0
    total_bytes = 0
    enc_seen = []
    for _ in range(nrect):
        rx, ry, rw, rh = struct.unpack(">HHHH", rq(s, 8))
        enc = struct.unpack(">i", rq(s, 4))[0]
        enc_seen.append(enc)
        if enc == 0:
            n = rw * rh * 4
            data = rq(s, n)
            total_bytes += len(data)
            total_bright += sum(1 for b in data if b > 16)
        else:
            # encoding non-Raw: kita tidak parse (cukup untuk diagnosa awal)
            pass
    print("VNC_RECTS=%d enc=%s" % (nrect, enc_seen))
    if total_bytes > 0:
        ratio = total_bright / float(total_bytes)
        verdict = "NONBLACK" if ratio > 0.002 else "BLACK"
        print("VNC_STREAM=%s bytes=%d bright_ratio=%.4f" % (verdict, total_bytes, ratio))
        if verdict == "NONBLACK":
            print("\n[KEPUTUSAN] Desktop & stream VNC terisi pixel nyata.\n  => Masalah kemungkinan ada di sisi noVNC/browser (bug noVNC+macaOS).")
            print("  => Coba: gerakkan mouse/klik di jendela noVNC, atau ganti web client.")
        else:
            print("\n[KEPUTUSAN] Stream VNC HITAM sekalipun dari client native.\n  => Masalah di ambilan layar screensharingd / virtual display,\n     bukan di browser. Lihat hint DISPLAY/DESKTOP di atas.")
    else:
        print("VNC_STREAM=NO_RAW_RECT (enc_seen=%s)" % (enc_seen,))
        print("\n[KEPUTUSAN] Screensharingd mengirim encoding non-Raw.\n  => Desktop setidaknya mengirim data — kemungkinan jalur noVNC/browser.")
except socket.timeout:
    print("VNC_STREAM=TIMEOUT (server lambat/tidak merespons)")
except EOFError as e:
    print("VNC_STREAM=EOF %r" % (e,))
except Exception as e:
    print("VNC_STREAM=SERVER_ERROR %r" % (e,))
finally:
    try:
        s.close()
    except Exception:
        pass
PYEOF
  else
    echo -e "${C_YELLOW}[INFO] VNC_STREAM=SKIP — port 5900 tidak menerima koneksi (TCP probe gagal).${C_NC}"
  fi
else
  echo -e "${C_YELLOW}[INFO] VNC_STREAM=SKIP — pycryptodome tidak terpasang & gagal di-install.${C_NC}"
fi

echo ""
echo "=============================================================="
echo -e "${C_BOLD}[vnc-probe]${C_NC} Selesai — salin log di atas untuk diagnosa."
echo "=============================================================="
exit 0