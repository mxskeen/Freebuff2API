# Freebuff2API

[English](README.md) | [简体中文](README_zh.md)

Freebuff2API is an OpenAI-compatible proxy server for [Freebuff](https://freebuff.com). It translates standard OpenAI API requests into Freebuff's backend format, allowing you to use Freebuff's free models with any OpenAI-compatible client, SDK, or CLI tool.

## Features

- **OpenAI Compatible API** — Standard OpenAI endpoints; works with any compatible client out of the box.
- **Stealth Request Handling** — Dynamic, randomized client fingerprints that mimic official Freebuff SDK behavior.
- **Multi-Token Rotation** — Cycle through multiple auth tokens with automatic periodic rotation.
- **HTTP & SOCKS5 Proxy Support** — Route all outbound traffic through HTTP, HTTPS, or SOCKS5 proxies (WARP, Shadowsocks, etc.) for regional bypass.
- **Cloudflare Quick Tunnels** — Built-in tunnel support exposes a public HTTPS URL with zero port forwarding or account setup.
- **Geo-Bypass Headers** — Inject spoofed upstream headers (`X-Forwarded-For`, `CF-Connecting-IP`, `X-Real-IP`) to handle regional restrictions.

## Getting Auth Tokens

Freebuff2API requires one or more Freebuff **auth tokens**. There are two ways to obtain one:

### Method 1 — Web (Recommended)

Visit **[https://freebuff.llm.pm](https://freebuff.llm.pm)**, log in with your Freebuff account, and your auth token will be displayed directly on the page. Copy it as your **AUTH_TOKENS** — no local installation required.

### Method 2 — Freebuff CLI

Install the Freebuff CLI:

```bash
npm i -g freebuff
```

Run `freebuff` in your terminal — on first launch it will guide you through login.

After logging in, your token is saved to a local credentials file:

| OS | Credentials Path |
|---|---|
| Windows | `C:\Users\<username>\.config\manicode\credentials.json` |
| Linux / macOS | `~/.config/manicode/credentials.json` |

The file looks like:

```json
{
  "default": {
    "id": "user_10293847",
    "name": "Zhang San",
    "email": "zhangsan@example.com",
    "authToken": "fa82b5c1-e39d-4c7a-961f-d2b3c4e5f6a7",
    ...
  }
}
```

Only the `authToken` value is needed — copy it as your **AUTH_TOKENS**.

> **Tip:** Log in with multiple accounts and configure all their tokens for higher throughput.

## Configuration

Configuration is managed via a JSON file and/or environment variables. The JSON keys and environment variable names are identical. By default the app looks for `config.json` in the working directory; use `-config` to specify another path.

```json
{
  "LISTEN_ADDR": ":8080",
  "UPSTREAM_BASE_URL": "https://codebuff.com",
  "AUTH_TOKENS": ["eyJhb..."],
  "ROTATION_INTERVAL": "6h",
  "REQUEST_TIMEOUT": "15m",
  "API_KEYS": [],
  "HTTP_PROXY": "",
  "UPSTREAM_HEADERS": {}
}
```

### Reference

| Key / Env Var | Description |
|---|---|
| `LISTEN_ADDR` | Proxy listen address (default `:8080`) |
| `UPSTREAM_BASE_URL` | Freebuff backend URL (default `https://codebuff.com`) |
| `AUTH_TOKENS` | Freebuff auth tokens (JSON array or comma-separated env var) |
| `ROTATION_INTERVAL` | Run rotation interval (default `6h`) |
| `REQUEST_TIMEOUT` | Upstream request timeout (default `15m`) |
| `API_KEYS` | Client API keys for proxy auth (empty = open access) |
| `HTTP_PROXY` | HTTP/SOCKS5 proxy for outbound requests (supports `socks5://`, `http://`, `https://`) |
| `UPSTREAM_HEADERS` | Upstream geo-spoof headers (JSON object, e.g. `{"X-Forwarded-For": "1.2.3.4"}`) |
Environment variables override JSON values when both are set.

## Deployment

### Termux Non-Root (Android) — Recommended

**No root, no TUN device, no OpenVPN.** Everything runs in userspace:

```bash
pkg install -y git
git clone https://github.com/mxskeen/Freebuff2API.git
cd Freebuff2API
chmod +x termux_start.sh
./termux_start.sh
```

The script automatically:
- Installs missing packages (`golang`, `curl`, `jq`, `git`)
- Downloads **warp-plus** (userspace SOCKS5 proxy) for ARM64 into `./bin/`
- Downloads **cloudflared** (Cloudflare Quick Tunnel) into `./bin/`
- Spawns `warp-plus` on `127.0.0.1:8086` for geo-bypass
- Builds and starts Freebuff2API routed through the SOCKS5 proxy
- Generates a public `https://*.trycloudflare.com` URL
- Prints a copy-paste ready OpenAI Base URL with `curl` test command

Architecture flow:
```
warp-plus (SOCKS5 :8086) → freebuff2api (:8080) → cloudflared (*.trycloudflare.com)
```

### Generic Linux Setup

For standard Linux (or Termux without warp-plus):

```bash
chmod +x start.sh
./start.sh
```

### Cloudflare Quick Tunnel

Expose a public HTTPS URL without port forwarding:

```bash
# Via start.sh (automatic)
./start.sh

# Via binary directly
./Freebuff2api -tunnel

# Via environment variable
ENABLE_TUNNEL=true ./Freebuff2API
```

The tunnel URL is printed to stdout and works immediately — no Cloudflare account needed.

### Docker

Pre-built multi-arch images are available on GHCR:

```bash
docker run -d --name Freebuff2API \
  -p 8080:8080 \
  -e AUTH_TOKENS="token1,token2" \
  ghcr.io/quorinex/freebuff2api:latest
```

Build from source:

```bash
docker build -t Freebuff2API .
docker run -d -p 8080:8080 -e AUTH_TOKENS="token1,token2" Freebuff2API
```

### Build from Source

**Requirements:** Go 1.23+

```bash
git clone https://github.com/Quorinex/Freebuff2API.git
cd Freebuff2API
go build -o Freebuff2API .
./Freebuff2API -config config.json
```

### SOCKS5/HTTP Proxy for Regional Bypass

Route upstream traffic through a proxy to bypass regional restrictions:

```json
{
  "HTTP_PROXY": "socks5://127.0.0.1:1080"
}
```

Or via environment:

```bash
export ALL_PROXY="socks5://127.0.0.1:1080"
./Freebuff2API
```

Supported schemes: `socks5://`, `socks5h://`, `http://`, `https://`.
Fallback order: `HTTP_PROXY` → `HTTPS_PROXY` → `ALL_PROXY` → `http_proxy`.

## Links

- [linux.do](https://linux.do)

## Disclaimer

This project has no official affiliation with OpenAI, Codebuff, or Freebuff. All related trademarks and copyrights belong to their respective owners.

All contents within this repository are provided solely for communication, experimentation, and learning, and do not constitute production-ready services or professional advice. This project is provided on an "As-Is" basis, and users must use it at their own risk. The author assumes no liability for any direct or indirect damages resulting from the use, modification, or distribution of this project, nor provides any warranties of any kind, express or implied.

## License

MIT
