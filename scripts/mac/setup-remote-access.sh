#!/bin/bash
# setup-remote-access.sh — macOS remote access via built-in Screen Sharing (VNC)
# + noVNC (browser desktop) + Cloudflare Quick Tunnel (no account, no API key).
#
# Alur:
#   1. Aktifkan Screen Sharing macOS bawaan (VNC server, port 5900) + set password
#   2. Cegah sleep/display sleep (desktop tetap hidup selama runner jalan)
#   3. Pasang noVNC + websockify  -> web UI browser  (port 6080, WebSocket->VNC TCP)
#   4. Pasang cloudflared (Homebrew) + jalankan Quick Tunnel
#      -> keluar URL publik https://<rand>.trycloudflare.com (browser-only, TLS)
#   5. Cetak URL koneksi ke stdout + /tmp/cf-tunnel-url.txt
#
# Cara pakai (dari GitHub Actions, sebagai user `runner`):
#   VNC_PASSWORD=somepass ./setup-remote-access.sh
#
# Prasyarat: GitHub-hosted macOS runner (user `runner`, sudo tanpa password),
#            Homebrew sudah terinstall di image.
#
# Catatan:
#   - Quick Tunnel (TryCloudflare) gratis & tanpa akun; URL acak, ephemeral.
#   - Screen Sharing macOS TIDAK butuh izin Screen Recording (TCC) — kernel
#     service `screensharingd` menangkap layar sebagai bagian dari tugasnya.
#   - Tidak butuh ngrok / Tailscale / secret apa pun.

set -euo pipefail

# ============================================================
# ANSI COLORS
# ============================================================
C_RED='\033[1;31m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_CYAN='\033[1;36m'
C_BOLD='\033[1m'
C_NC='\033[0m'

echo ""
echo "=============================================================="
echo -e "${C_BOLD}[setup-remote-access]${C_NC} macOS remote access (VNC + noVNC + Cloudflare Quick Tunnel)"
echo "=============================================================="

# Mask password dari log Actions sejak awal.
VNC_PASSWORD="${VNC_PASSWORD:-}"
if [ -z "$VNC_PASSWORD" ]; then
  echo -e "${C_RED}[FAIL] VNC_PASSWORD wajib diisi (min 6 karakter).${C_NC}"
  exit 1
fi
if [ "${#VNC_PASSWORD}" -lt 6 ]; then
  echo -e "${C_RED}[FAIL] VNC_PASSWORD minimal 6 karakter.${C_NC}"
  exit 1
fi
# add-mask hanya berlaku saat script dipanggil dari runner GitHub Actions.
echo "::add-mask::$VNC_PASSWORD" 2>/dev/null || true

# ============================================================
# STEP 1: AKTIFKAN SCREEN SHARING (VNC) + SET PASSWORD
# ============================================================
echo ""
echo -e "${C_CYAN}[1/5] Mengaktifkan Screen Sharing (VNC) ...${C_NC}"

KICKSTART="/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart"
if [ ! -x "$KICKSTART" ]; then
  echo -e "${C_RED}[FAIL] ARDAgent kickstart tidak ditemukan: $KICKSTART${C_NC}"
  exit 1
fi

# Set password akun `runner` (dipakai bila klien pakai username/password).
# Catatan (macOS 15/Sequoia): `dscl . -passwd` untuk user lokal dengan secure
# token menolak reset via root (DS Error -14090 eDSAuthFailed). Maka:
#   1) coba dscl dulu (`</dev/null` agar prompt password lama langsung EOF),
#   2) fallback ke `sysadminctl -resetPasswordFor` (pengganti resmi, tanpa
#      password lama),
#   3) jika keduanya gagal -> non-fatal: auth noVNC tetap lewat VNC password
#      yang di-set via `kickstart -setvncpw`, bukan password user macOS.
set_runner_password() {
  if sudo dscl . -passwd /Users/runner "$VNC_PASSWORD" </dev/null >/dev/null 2>&1; then
    echo -e "${C_GREEN}[OK] Password user 'runner' diset via dscl.${C_NC}"
    return 0
  fi

  if sudo sysadminctl -resetPasswordFor runner -newPassword "$VNC_PASSWORD" >/dev/null 2>&1; then
    echo -e "${C_GREEN}[OK] Password user 'runner' diset via sysadminctl.${C_NC}"
    return 0
  fi

  echo -e "${C_YELLOW}[WARN] Tidak bisa set password user 'runner'; lanjut.\n      (Auth noVNC memakai VNC password dari kickstart -setvncpw.)${C_NC}"
  return 0
}
set_runner_password

# Aktifkan Remote Management / Screen Sharing + VNC-only password (legacy).
# `-setvnclegacy` membuat koneksi raw VNC (noVNC / RealVNC / mstsc) dapat
# masuk memakai password VNC saja, tidak perlu username macOS.
sudo "$KICKSTART" \
  -activate \
  -configure -allowAccessFor -allUsers \
  -privs -all \
  -restart \
  -agent \
  -clientopts -setmenuextra -menuextra yes \
  -clientopts -setvnclegacy -vnclegacy yes \
  -clientopts -setvncpw -vncpw "$VNC_PASSWORD" \
  -configure -access -on

# Fallback (macOS 14+ VMs): kickstart bisa mengkonfigurasi service tanpa
# benar-benar memulai screensharingd. Launchctl memaksa daemon jalan.
echo -e "${C_CYAN}[1/5] Memaksa screensharingd via launchctl (fallback untuk VM)...${C_NC}"
sudo launchctl enable system/com.apple.screensharing 2>/dev/null || true
sudo launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist 2>/dev/null || true
sleep 3

# Self-check port VNC (5900) — retry loop 10 × 3 detik.
echo -e "${C_CYAN}[1/5] Menunggu port 5900 ...${C_NC}"
MAX_VNC_ATTEMPTS=10
VNC_ATTEMPT=0
while [ "$VNC_ATTEMPT" -lt "$MAX_VNC_ATTEMPTS" ]; do
  if lsof -nP -iTCP:5900 -sTCP:LISTEN >/dev/null 2>&1; then
    echo -e "${C_GREEN}[OK] Screen Sharing aktif di port 5900.${C_NC}"
    break
  fi
  VNC_ATTEMPT=$((VNC_ATTEMPT + 1))
  echo -e "${C_YELLOW}  Attempt ${VNC_ATTEMPT}/${MAX_VNC_ATTEMPTS} — port 5900 belum aktif, tunggu 3s ...${C_NC}"
  sleep 3
done

if [ "$VNC_ATTEMPT" -eq "$MAX_VNC_ATTEMPTS" ]; then
  echo -e "${C_RED}[FAIL] Port 5900 tidak aktif setelah ${MAX_VNC_ATTEMPTS} percobaan.${C_NC}"
  echo ""
  echo "------------------------------------------------------------"
  echo "  DIAGNOSTIC SCREENSHARING (detail untuk debugging)"
  echo "------------------------------------------------------------"
  echo "  launchctl status screensharingd:"
  sudo launchctl list com.apple.screensharing 2>&1 || echo "    (not found)"
  echo ""
  echo "  Proses screensharingd:"
  ps aux 2>/dev/null | grep -i screensharing | grep -v grep || echo "    (tidak jalan)"
  echo ""
  echo "  Semua port listening:"
  sudo lsof -nP -iTCP -sTCP:LISTEN -P -n 2>/dev/null | head -30 || echo "    (tidak ada)"
  echo ""
  echo "  Kickstart log (last 10 lines):"
  cat /var/log/kickstart.log 2>/dev/null | tail -n 10 || echo "    (tidak ada)"
  echo ""
  echo "  LoginWindow:"
  ps aux 2>/dev/null | grep -i loginwindow | grep -v grep || echo "    (tidak ditemukan)"
  echo "------------------------------------------------------------"
  echo -e "${C_YELLOW}[WARN] Lanjut ke noVNC — port 5900 belum aktif.${C_NC}"
fi

# ============================================================
# STEP 2: CEGAH SLEEP
# ============================================================
echo ""
echo -e "${C_CYAN}[2/5] Mencegah sleep / display sleep ...${C_NC}"
sudo pmset -a displaysleep 0 sleep 0 disablesleep 1 2>/dev/null || true
caffeinate -dimsu >/dev/null 2>&1 &
echo -e "${C_GREEN}[OK] Sleep di-nonaktifkan + caffeinate jalan di background.${C_NC}"

# ============================================================
# STEP 3: INSTALL & START noVNC + WEBSOCKIFY
# ============================================================
echo ""
echo -e "${C_CYAN}[3/5] Memasang noVNC + websockify ...${C_NC}"

NOVNC_DIR="${NOVNC_DIR:-/tmp/noVNC}"
if [ ! -d "$NOVNC_DIR/.git" ]; then
  rm -rf "$NOVNC_DIR"
  git clone --depth 1 https://github.com/novnc/noVNC.git "$NOVNC_DIR"
fi

# websockify = WebSocket -> TCP bridge. Repo noVNC menjadikannya submodule
# yang tidak ikut ter-clone dengan --depth 1, jadi clone manual.
if [ ! -f "$NOVNC_DIR/utils/websockify/run" ]; then
  git clone --depth 1 https://github.com/novnc/websockify.git "$NOVNC_DIR/utils/websockify"
fi

pkill -f 'novnc_proxy' 2>/dev/null || true
pkill -f 'websockify' 2>/dev/null || true
nohup "$NOVNC_DIR/utils/novnc_proxy" \
  --vnc localhost:5900 \
  --listen 127.0.0.1:6080 \
  >/tmp/novnc.log 2>&1 &

# Tunggu web UI siap.
NOVNC_READY=0
for _ in $(seq 1 15); do
  if curl -sf "http://127.0.0.1:6080/vnc.html" >/dev/null 2>&1; then
    NOVNC_READY=1
    break
  fi
  sleep 1
done
if [ "$NOVNC_READY" -eq 1 ]; then
  echo -e "${C_GREEN}[OK] noVNC berjalan: http://127.0.0.1:6080/vnc.html${C_NC}"
else
  echo -e "${C_RED}[FAIL] noVNC tidak merespons di port 6080. Log:${C_NC}"
  tail -n 20 /tmp/novnc.log 2>/dev/null || true
  exit 1
fi

# ============================================================
# STEP 4: INSTALL cloudflared + START QUICK TUNNEL
# ============================================================
echo ""
echo -e "${C_CYAN}[4/5] Memasang cloudflared (Homebrew) ...${C_NC}"
if ! command -v cloudflared >/dev/null 2>&1; then
  # Coba formula resmi di homebrew-core dulu, fallback ke tap homebrew-cloudflare.
  echo -e "${C_YELLOW}[INFO] brew install cloudflared (homebrew-core)...${C_NC}"
  brew install cloudflared || {
    echo -e "${C_YELLOW}[INFO] Fallback ke tap cloudflare/cloudflare/cloudflared...${C_NC}"
    brew install cloudflare/cloudflare/cloudflared
  }
fi
cloudflared --version

echo -e "${C_CYAN}[4/5] Membuka Cloudflare Quick Tunnel ...${C_NC}"

# Quick Tunnel: tanpa akun, tanpa API token. cloudflared bikin koneksi
# outbound ke Cloudflare lalu mendapat URL acak *.trycloudflare.com.
pkill -f 'cloudflared tunnel --url' 2>/dev/null || true
nohup cloudflared tunnel \
  --url http://127.0.0.1:6080 \
  --no-autoupdate \
  >/tmp/cloudflared.log 2>&1 &

TUNNEL_URL=""
for _ in $(seq 1 45); do
  TUNNEL_URL=$(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' /tmp/cloudflared.log | head -n1 || true)
  if [ -n "$TUNNEL_URL" ]; then
    break
  fi
  sleep 1
done

if [ -z "$TUNNEL_URL" ]; then
  echo -e "${C_RED}[FAIL] Quick Tunnel gagal dibuat. Log cloudflared:${C_NC}"
  tail -n 25 /tmp/cloudflared.log 2>/dev/null || true
  exit 1
fi

# Simpan URL ke file agar step Verify/Keep Alive di workflow bisa membacanya.
echo "$TUNNEL_URL" > /tmp/cf-tunnel-url.txt
chmod 644 /tmp/cf-tunnel-url.txt

# ============================================================
# STEP 5: CETAK INSTRUKSI KONEKSI
# ============================================================
echo ""
echo "=============================================================="
echo -e "${C_GREEN}      [OK] MACOS REMOTE DESKTOP READY${C_NC}"
echo "=============================================================="
echo -e "      [INFO] Open in your browser :"
echo -e "      ${C_CYAN}${TUNNEL_URL}/vnc.html${C_NC}"
echo -e "      [INFO] Connection type     : noVNC (web) + Cloudflare Quick Tunnel"
echo -e "      [INFO] User                : runner"
echo -e "      [INFO] VNC Password        : $VNC_PASSWORD"
echo -e "      [INFO] Direct VNC          : vnc://localhost:5900 (local only)"
echo "=============================================================="

echo -e "${C_GREEN}[OK] ${C_NC}URL tunnel tersimpan di ${C_CYAN}/tmp/cf-tunnel-url.txt${C_NC}"
exit 0