#!/usr/bin/env bash
# Freebuff2API — One-command setup & launcher
# Works on Linux (amd64/arm64) and Termux (Android) without root.

set -euo pipefail

BINARY_NAME="freebuff2api"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ─── Color helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { printf "${CYAN}[INFO]${NC}  %s\n" "$*"; }
ok()    { printf "${GREEN}[OK]${NC}    %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
die()   { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; exit 1; }

# ─── Environment detection ─────────────────────────────────────────────────
IS_TERMUX=false
if [ -n "${PREFIX:-}" ] && echo "$PREFIX" | grep -q "com.termux"; then
    IS_TERMUX=true
fi
if [ -d "/data/data/com.termux" ]; then
    IS_TERMUX=true
fi

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64|amd64)   CF_ARCH="amd64" ;;
    aarch64|arm64)   CF_ARCH="arm64" ;;
    armv7l|armhf)    CF_ARCH="arm"   ;;
    *)               die "Unsupported architecture: $ARCH" ;;
esac

if [ "$IS_TERMUX" = true ]; then
    info "Running in Termux (Android $ARCH)"
else
    info "Running on Linux ($ARCH)"
fi

# ─── Install dependencies ──────────────────────────────────────────────────
install_deps_termux() {
    info "Installing dependencies via pkg..."
    pkg update -y 2>/dev/null || true
    for cmd in go git curl jq; do
        if ! command -v "$cmd" &>/dev/null; then
            info "Installing $cmd..."
            pkg install -y "$cmd" 2>/dev/null || warn "Failed to install $cmd"
        fi
    done
}

install_deps_linux() {
    info "Checking dependencies..."
    local missing=()
    for cmd in go git curl jq; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        warn "Missing: ${missing[*]}"
        if command -v apt-get &>/dev/null; then
            info "Installing via apt-get (may need sudo)..."
            sudo apt-get update -y 2>/dev/null || true
            sudo apt-get install -y "${missing[@]}" 2>/dev/null || warn "Some packages failed to install"
        elif command -v apk &>/dev/null; then
            info "Installing via apk..."
            apk add --no-cache "${missing[@]}" 2>/dev/null || warn "Some packages failed to install"
        elif command -v dnf &>/dev/null; then
            info "Installing via dnf..."
            sudo dnf install -y "${missing[@]}" 2>/dev/null || warn "Some packages failed to install"
        else
            die "Cannot auto-install ${missing[*]}. Please install them manually."
        fi
    fi
}

if [ "$IS_TERMUX" = true ]; then
    install_deps_termux
else
    install_deps_linux
fi

# Verify Go is available
command -v go &>/dev/null || die "Go is not installed. Visit https://go.dev/dl/ or run: pkg install golang"

GO_VERSION="$(go version | grep -oP 'go\d+\.\d+' | head -1)"
ok "Go $GO_VERSION detected"

# ─── Download cloudflared if missing ───────────────────────────────────────
install_cloudflared() {
    if command -v cloudflared &>/dev/null; then
        ok "cloudflared already installed"
        return
    fi

    info "Downloading cloudflared for $CF_ARCH..."

    local cf_url=""
    local tmp_file="/tmp/cloudflared"

    if [ "$IS_TERMUX" = true ]; then
        # Termux — download the static binary
        case "$CF_ARCH" in
            arm64)  cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
            arm)    cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm" ;;
            *)      cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
        esac
    else
        case "$CF_ARCH" in
            arm64)  cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
            arm)    cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm" ;;
            *)      cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
        esac
    fi

    if curl -fsSL "$cf_url" -o "$tmp_file"; then
        chmod +x "$tmp_file"
        # Try to place in PATH-accessible location
        local target_dir="$SCRIPT_DIR"
        if [ -w "/usr/local/bin" ] 2>/dev/null; then
            target_dir="/usr/local/bin"
        elif [ "$IS_TERMUX" = true ] && [ -w "$PREFIX/bin" ] 2>/dev/null; then
            target_dir="$PREFIX/bin"
        fi
        mv "$tmp_file" "$target_dir/cloudflared"
        ok "cloudflared installed to $target_dir/cloudflared"
        # Update PATH if we installed to script dir
        if [ "$target_dir" = "$SCRIPT_DIR" ]; then
            export PATH="$SCRIPT_DIR:$PATH"
        fi
    else
        warn "Failed to download cloudflared. Tunnel will not be available."
        warn "Manual install: https://github.com/cloudflare/cloudflared/releases"
    fi
}

install_cloudflared

# ─── Config wizard ─────────────────────────────────────────────────────────
CONFIG_FILE="$SCRIPT_DIR/config.json"

if [ ! -f "$CONFIG_FILE" ]; then
    info "No config.json found. Running configuration wizard..."
    echo ""

    # AUTH_TOKENS
    printf "${BOLD}Enter your Freebuff AUTH_TOKENS${NC} (comma-separated, or press Enter to use .env):\n> "
    read -r AUTH_INPUT

    AUTH_TOKENS_JSON="[]"
    if [ -n "$AUTH_INPUT" ]; then
        # Convert comma-separated to JSON array
        AUTH_TOKENS_JSON=$(echo "$AUTH_INPUT" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | jq -R . | jq -s .)
    elif [ -f "$SCRIPT_DIR/.env" ]; then
        source "$SCRIPT_DIR/.env" 2>/dev/null || true
        if [ -n "${AUTH_TOKENS:-}" ]; then
            AUTH_TOKENS_JSON=$(echo "$AUTH_TOKENS" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | jq -R . | jq -s .)
        fi
    fi

    # HTTP_PROXY (optional)
    printf "${BOLD}HTTP Proxy${NC} (socks5://host:port or http://host:port, Enter to skip):\n> "
    read -r PROXY_INPUT

    # API_KEYS (optional)
    printf "${BOLD}API Keys for client auth${NC} (comma-separated, Enter for open access):\n> "
    read -r APIKEY_INPUT
    API_KEYS_JSON="[]"
    if [ -n "$APIKEY_INPUT" ]; then
        API_KEYS_JSON=$(echo "$APIKEY_INPUT" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | jq -R . | jq -s .)
    fi

    # UPSTREAM_HEADERS (optional)
    printf "${BOLD}Spoofed upstream headers${NC} (e.g. X-Forwarded-For:1.2.3.4, Enter to skip):\n> "
    read -r HEADERS_INPUT
    HEADERS_JSON="{}"
    if [ -n "$HEADERS_INPUT" ]; then
        HEADERS_JSON=$(echo "$HEADERS_INPUT" | tr ',' '\n' | while IFS=: read -r k v; do
            echo "$k:$v"
        done | jq -R 'split(":") | {(.[0]): .[1:] | join(":")}' | jq -s 'add // {}')
    fi

    cat > "$CONFIG_FILE" <<EOCONFIG
{
  "LISTEN_ADDR": ":8080",
  "UPSTREAM_BASE_URL": "https://www.codebuff.com",
  "AUTH_TOKENS": $AUTH_TOKENS_JSON,
  "ROTATION_INTERVAL": "6h",
  "REQUEST_TIMEOUT": "15m",
  "API_KEYS": $API_KEYS_JSON,
  "HTTP_PROXY": "${PROXY_INPUT:-}",
  "UPSTREAM_HEADERS": $HEADERS_JSON
}
EOCONFIG
    ok "Config written to $CONFIG_FILE"
    echo ""
fi

# ─── Build ─────────────────────────────────────────────────────────────────
info "Building $BINARY_NAME..."
go build -o "$BINARY_NAME" . || die "Build failed"
ok "Build complete: $SCRIPT_DIR/$BINARY_NAME"

# ─── Process management ────────────────────────────────────────────────────
SERVER_PID=""

cleanup() {
    echo ""
    info "Shutting down..."
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    ok "All processes stopped."
    exit 0
}
trap cleanup SIGINT SIGTERM EXIT

# ─── Resolve health-check port from config ─────────────────────────────────
HEALTH_PORT=$(jq -r '.LISTEN_ADDR // ":8080"' "$CONFIG_FILE" | sed 's/^://')
info "Starting Freebuff2API server (port $HEALTH_PORT)..."
"./$BINARY_NAME" -tunnel &
SERVER_PID=$!

# Wait for the server to be ready
for i in $(seq 1 30); do
    if curl -sf "http://localhost:${HEALTH_PORT}/healthz" >/dev/null 2>&1; then
        ok "Server is ready"
        break
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        die "Server process exited unexpectedly"
    fi
    sleep 0.5
done

# Keep running — the Go binary handles tunnel and banner internally
wait "$SERVER_PID" 2>/dev/null || true
