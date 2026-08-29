#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# Freebuff2API — Termux Non-Root One-Command Launcher
# Runs entirely in userspace — no TUN device, no root, no OpenVPN.
#
# Architecture:
#   warp-plus (SOCKS5 @ 127.0.0.1:8086)
#       ↓
#   freebuff2api (OpenAI-compatible gateway @ :8080)
#       ↓
#   cloudflared (public HTTPS tunnel → *.trycloudflare.com)
# ═══════════════════════════════════════════════════════════════════════════

set -euo pipefail

BINARY_NAME="freebuff2api"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$SCRIPT_DIR/bin"
CONFIG_FILE="$SCRIPT_DIR/config.json"
cd "$SCRIPT_DIR"

# ─── Constants ─────────────────────────────────────────────────────────────
PROXY_PORT=8086
PROXY_ADDR="socks5://127.0.0.1:${PROXY_PORT}"
LISTEN_PORT=8080

# ─── Color helpers ─────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()  { printf "${CYAN}[INFO]${NC}  %s\n" "$*"; }
ok()    { printf "${GREEN}[ OK ]${NC}  %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
die()   { printf "${RED}[FAIL]${NC} %s\n" "$*" >&2; exit 1; }

# ─── Architecture detection ───────────────────────────────────────────────
ARCH="$(uname -m)"
case "$ARCH" in
    aarch64|arm64)  CF_ARCH="arm64"; WP_ARCH="arm64" ;;
    x86_64|amd64)   CF_ARCH="amd64"; WP_ARCH="amd64" ;;
    armv7l|armhf)   CF_ARCH="arm";   WP_ARCH="arm"   ;;
    *)              die "Unsupported architecture: $ARCH" ;;
esac

# ─── Termux detection ─────────────────────────────────────────────────────
IS_TERMUX=false
if [ -n "${PREFIX:-}" ] && echo "$PREFIX" | grep -q "com.termux"; then
    IS_TERMUX=true
elif [ -d "/data/data/com.termux" ]; then
    IS_TERMUX=true
fi

if [ "$IS_TERMUX" != true ]; then
    warn "Not running in Termux — this script is optimized for Android/Termux."
    warn "Consider using start.sh for standard Linux."
fi

info "Platform: Termux/$ARCH"

# ─── Install Termux packages ──────────────────────────────────────────────
install_termux_deps() {
    info "Checking Termux packages..."
    local missing=()
    for cmd in go curl jq git; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        info "Installing: ${missing[*]}..."
        pkg update -y 2>/dev/null || true
        pkg install -y "${missing[@]}" 2>/dev/null || die "Failed to install ${missing[*]}"
        ok "Packages installed"
    else
        ok "All packages present"
    fi
}

install_termux_deps

# Verify Go
command -v go &>/dev/null || die "Go not found. Run: pkg install golang"
ok "Go $(go version | grep -oP 'go\d+\.\d+' | head -1)"
# ─── Download warp-plus (userspace SOCKS5 proxy) ──────────────────────────
# Skip when SKIP_WARP_PLUS=1 is set (e.g. when a paid VPN is already routing
# Termux through a non-restricted exit — adding warp-plus on top is just extra
# latency with no net effect on the exit IP).
install_warp_plus() {
    if [ "${SKIP_WARP_PLUS:-0}" = "1" ]; then
        info "SKIP_WARP_PLUS=1 — skipping warp-plus (using your VPN directly)"
        return
    fi
    if command -v warp-plus &>/dev/null; then
        ok "warp-plus found in PATH"
        return
    fi
    if [ -x "$BIN_DIR/warp-plus" ]; then
        ok "warp-plus found in $BIN_DIR"
        export PATH="$BIN_DIR:$PATH"
        return
    fi

    info "Downloading warp-plus for $WP_ARCH..."
    mkdir -p "$BIN_DIR"

    # Primary: bia-pain-bache/warp-plus releases
    local wp_url="https://github.com/bia-pain-bache/warp-plus/releases/latest/download/warp-plus_linux_${WP_ARCH}"
    if curl -fsSL --connect-timeout 15 --max-time 120 "$wp_url" -o "$BIN_DIR/warp-plus" 2>/dev/null; then
        chmod +x "$BIN_DIR/warp-plus"
        export PATH="$BIN_DIR:$PATH"
        ok "warp-plus installed to $BIN_DIR/warp-plus"
        return
    fi

    # Fallback: vardanharutyunyan/warp-plus
    local wp_url2="https://github.com/vardanharutyunyan/warp-plus/releases/latest/download/warp-plus-linux-${WP_ARCH}"
    if curl -fsSL --connect-timeout 15 --max-time 120 "$wp_url2" -o "$BIN_DIR/warp-plus" 2>/dev/null; then
        chmod +x "$BIN_DIR/warp-plus"
        export PATH="$BIN_DIR:$PATH"
        ok "warp-plus installed to $BIN_DIR/warp-plus"
        return
    fi

    warn "Failed to download warp-plus. You can:"
    warn "  1. Manually place a warp-plus binary in $BIN_DIR/"
    warn "  2. Set HTTP_PROXY to your own SOCKS5/HTTP proxy in config.json"
    warn "Continuing without auto-proxy (geo-restricted models may fail)..."
}

# ─── Download cloudflared ─────────────────────────────────────────────────
install_cloudflared() {
    if command -v cloudflared &>/dev/null; then
        ok "cloudflared found in PATH"
        return
    fi
    if [ -x "$BIN_DIR/cloudflared" ]; then
        ok "cloudflared found in $BIN_DIR"
        export PATH="$BIN_DIR:$PATH"
        return
    fi

    info "Downloading cloudflared for $CF_ARCH..."
    mkdir -p "$BIN_DIR"

    local cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
    if curl -fsSL --connect-timeout 15 --max-time 120 "$cf_url" -o "$BIN_DIR/cloudflared"; then
        chmod +x "$BIN_DIR/cloudflared"
        export PATH="$BIN_DIR:$PATH"
        ok "cloudflared installed to $BIN_DIR/cloudflared"
    else
        warn "Failed to download cloudflared. Tunnel will not be available."
    fi
}

install_cloudflared

# ─── Config wizard ────────────────────────────────────────────────────────
if [ ! -f "$CONFIG_FILE" ]; then
    info "No config.json found — running quick setup..."
    echo ""

    printf "${BOLD}Enter Freebuff AUTH_TOKENS${NC} (comma-separated):\n> "
    read -r AUTH_INPUT

    if [ -z "$AUTH_INPUT" ]; then
        # Try .env
        if [ -f "$SCRIPT_DIR/.env" ]; then
            source "$SCRIPT_DIR/.env" 2>/dev/null || true
            AUTH_INPUT="${AUTH_TOKENS:-}"
        fi
    fi

    if [ -z "$AUTH_INPUT" ]; then
        die "No auth tokens provided. Get one at https://freebuff.llm.pm"
    fi

    AUTH_TOKENS_JSON=$(echo "$AUTH_INPUT" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | jq -R . | jq -s .)

    printf "${BOLD}API Keys for client auth${NC} (comma-separated, Enter=open access):\n> "
    read -r APIKEY_INPUT
    API_KEYS_JSON="[]"
    if [ -n "$APIKEY_INPUT" ]; then
        API_KEYS_JSON=$(echo "$APIKEY_INPUT" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | jq -R . | jq -s .)
    fi

    # Use warp-plus proxy by default if available
    DEFAULT_PROXY=""
    if [ "${SKIP_WARP_PLUS:-0}" != "1" ] && { [ -x "$BIN_DIR/warp-plus" ] || command -v warp-plus &>/dev/null; }; then
        DEFAULT_PROXY="$PROXY_ADDR"
    fi

    cat > "$CONFIG_FILE" <<EOCONFIG
{
  "LISTEN_ADDR": ":${LISTEN_PORT}",
  "UPSTREAM_BASE_URL": "https://www.codebuff.com",
  "AUTH_TOKENS": $AUTH_TOKENS_JSON,
  "ROTATION_INTERVAL": "6h",
  "REQUEST_TIMEOUT": "15m",
  "API_KEYS": $API_KEYS_JSON,
  "HTTP_PROXY": "${DEFAULT_PROXY}",
  "UPSTREAM_HEADERS": {}
}
EOCONFIG
    ok "Config written to $CONFIG_FILE"
    echo ""
fi

# Read back the configured port and proxy
LISTEN_PORT=$(jq -r '.LISTEN_ADDR // ":8080"' "$CONFIG_FILE" | sed 's/^://')
CONFIGURED_PROXY=$(jq -r '.HTTP_PROXY // ""' "$CONFIG_FILE")

# If SKIP_WARP_PLUS=1 is set, clear any cached SOCKS5 proxy from a prior run.
if [ "${SKIP_WARP_PLUS:-0}" = "1" ] && [ -n "$CONFIGURED_PROXY" ]; then
    info "SKIP_WARP_PLUS=1 — clearing cached HTTP_PROXY ($CONFIGURED_PROXY) from config.json"
    tmp=$(mktemp)
    jq 'del(.HTTP_PROXY) | .HTTP_PROXY = ""' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
    CONFIGURED_PROXY=""
fi
# ─── Build ────────────────────────────────────────────────────────────────
info "Building $BINARY_NAME..."
go build -o "$BINARY_NAME" . || die "Build failed"
ok "Built $SCRIPT_DIR/$BINARY_NAME"

# ─── Process tracking ─────────────────────────────────────────────────────
WARP_PID=""
SERVER_PID=""
CF_PID=""

cleanup() {
    echo ""
    info "Shutting down..."
    for pid_var in CF_PID SERVER_PID WARP_PID; do
        eval "pid=\$$pid_var"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
    ok "All processes stopped."
    exit 0
}
trap cleanup SIGINT SIGTERM EXIT

# ─── Start warp-plus SOCKS5 proxy ─────────────────────────────────────────
WARP_BIN=""
if [ "${SKIP_WARP_PLUS:-0}" != "1" ]; then
    if command -v warp-plus &>/dev/null; then
        WARP_BIN="warp-plus"
    elif [ -x "$BIN_DIR/warp-plus" ]; then
        WARP_BIN="$BIN_DIR/warp-plus"
    fi
fi

# Only start warp-plus if config doesn't already have a proxy set
if [ -z "$CONFIGURED_PROXY" ] && [ -n "$WARP_BIN" ]; then
    info "Starting warp-plus SOCKS5 proxy on 127.0.0.1:${PROXY_PORT}..."
    "$WARP_BIN" --bind "127.0.0.1:${PROXY_PORT}" &
    WARP_PID=$!

    # Wait for proxy to be ready
    for i in $(seq 1 20); do
        if curl -sf --socks5 "127.0.0.1:${PROXY_PORT}" "http://ifconfig.me" >/dev/null 2>&1; then
            ok "warp-plus proxy is ready"
            break
        fi
        if [ "$i" -eq 20 ]; then
            warn "warp-plus may not be ready yet (continuing anyway)"
        fi
        sleep 0.5
    done

    # Inject proxy into config if not set
    if [ -z "$CONFIGURED_PROXY" ]; then
        CONFIGURED_PROXY="$PROXY_ADDR"
        tmp=$(mktemp)
        jq --arg proxy "$PROXY_ADDR" '.HTTP_PROXY = $proxy' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
        info "Injected HTTP_PROXY=$PROXY_ADDR into config.json"
    fi
elif [ -n "$CONFIGURED_PROXY" ]; then
    info "Using configured proxy: $CONFIGURED_PROXY"
else
    warn "No SOCKS5 proxy available. Geo-restricted models may fail."
    warn "Install warp-plus or set HTTP_PROXY in config.json."
fi

# ─── Start Freebuff2API ───────────────────────────────────────────────────
info "Starting Freebuff2API on port ${LISTEN_PORT}..."
"./$BINARY_NAME" &
SERVER_PID=$!

# Wait for server readiness
for i in $(seq 1 30); do
    if curl -sf "http://localhost:${LISTEN_PORT}/healthz" >/dev/null 2>&1; then
        ok "Freebuff2API is ready"
        break
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        die "Freebuff2API exited unexpectedly"
    fi
    sleep 0.5
done

# ─── Start Cloudflare Quick Tunnel ────────────────────────────────────────
TUNNEL_URL=""

if command -v cloudflared &>/dev/null; then
    info "Starting Cloudflare Quick Tunnel..."
    CF_LOG=$(mktemp)
    cloudflared tunnel --url "http://127.0.0.1:${LISTEN_PORT}" 2>&1 | tee "$CF_LOG" &
    CF_PID=$!

    # Parse tunnel URL from output
    for i in $(seq 1 60); do
        if [ -f "$CF_LOG" ]; then
            TUNNEL_URL=$(grep -oP 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$CF_LOG" | head -1) || true
            if [ -n "$TUNNEL_URL" ]; then
                ok "Tunnel established"
                break
            fi
        fi
        if [ "$i" -eq 60 ]; then
            warn "Could not parse tunnel URL after 30s"
        fi
        sleep 0.5
    done
    rm -f "$CF_LOG"
else
    warn "cloudflared not found. No public tunnel will be created."
fi

# ─── Print banner ─────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  🚀 Freebuff2API — Termux Non-Root Launcher${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}Local URL:${NC}      http://localhost:${LISTEN_PORT}/v1"

if [ -n "$TUNNEL_URL" ]; then
    echo -e "  ${BOLD}Public BaseURL:${NC} ${GREEN}${TUNNEL_URL}/v1${NC}"
else
    echo -e "  ${BOLD}Public BaseURL:${NC} ${DIM}(tunnel not available)${NC}"
fi

if [ -n "$CONFIGURED_PROXY" ]; then
    echo -e "  ${BOLD}Proxy:${NC}         ${CONFIGURED_PROXY}"
else
    echo -e "  ${BOLD}Proxy:${NC}         ${DIM}(none — direct connection)${NC}"
fi

echo ""
echo -e "  ${BOLD}📋 Sample Usage:${NC}"

if [ -n "$TUNNEL_URL" ]; then
    SAMPLE_URL="${TUNNEL_URL}/v1/chat/completions"
else
    SAMPLE_URL="http://localhost:${LISTEN_PORT}/v1/chat/completions"
fi

echo -e "  ${DIM}curl ${SAMPLE_URL} \\${NC}"
echo -e "  ${DIM}  -H \"Content-Type: application/json\" \\${NC}"
echo -e "  ${DIM}  -H \"Authorization: Bearer any-key\" \\${NC}"
echo -e "  ${DIM}  -d '{\"model\": \"deepseek-chat\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello!\"}]}'${NC}"
echo ""
echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
echo -e "  ${DIM}Press Ctrl+C to stop all processes${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
echo ""

# ─── Wait for signal ──────────────────────────────────────────────────────
wait "$SERVER_PID" 2>/dev/null || true
