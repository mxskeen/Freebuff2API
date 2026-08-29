package main

import (
	"bufio"
	"fmt"
	"io"
	"log"
	"os/exec"
	"regexp"
	"strings"
	"sync"
	"time"
)

// Tunnel manages a cloudflared quick tunnel process.
type Tunnel struct {
	cmd     *exec.Cmd
	url     string
	ready   chan struct{}
	logger  *log.Logger
	port    int
	stopped chan struct{}
	once    sync.Once
}

// NewTunnel creates a tunnel manager for the given local port.
func NewTunnel(port int, logger *log.Logger) *Tunnel {
	return &Tunnel{
		logger:  logger,
		port:    port,
		ready:   make(chan struct{}),
		stopped: make(chan struct{}),
	}
}

// Start launches cloudflared and waits for the public URL.
// Returns the tunnel URL or an error if startup fails.
func (t *Tunnel) Start() (string, error) {
	binary, err := exec.LookPath("cloudflared")
	if err != nil {
		return "", fmt.Errorf("cloudflared not found in PATH: %w (install with: curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o cloudflared && chmod +x cloudflared)", err)
	}

	localURL := fmt.Sprintf("http://localhost:%d", t.port)
	t.cmd = exec.Command(binary, "tunnel", "--url", localURL)

	stdout, err := t.cmd.StdoutPipe()
	if err != nil {
		return "", fmt.Errorf("cloudflared stdout pipe: %w", err)
	}
	stderr, err := t.cmd.StderrPipe()
	if err != nil {
		return "", fmt.Errorf("cloudflared stderr pipe: %w", err)
	}

	if err := t.cmd.Start(); err != nil {
		return "", fmt.Errorf("start cloudflared: %w", err)
	}

	// Parse combined output for the tunnel URL
	go t.parseOutput(io.MultiReader(stdout, stderr))
	go func() {
		t.cmd.Wait()
		close(t.stopped)
	}()

	select {
	case <-t.ready:
		return t.url, nil
	case <-t.stopped:
		return "", fmt.Errorf("cloudflared exited before publishing URL")
	case <-time.After(30 * time.Second):
		t.Kill()
		return "", fmt.Errorf("timeout waiting for cloudflared tunnel URL (30s)")
	}
}

var tunnelURLPattern = regexp.MustCompile(`https://[a-zA-Z0-9-]+\.trycloudflare\.com`)

func (t *Tunnel) parseOutput(r io.Reader) {
	scanner := bufio.NewScanner(r)
	for scanner.Scan() {
		line := scanner.Text()

		// Log cloudflared output for debugging
		if strings.Contains(line, "ERR") || strings.Contains(line, "err") {
			t.logger.Printf("cloudflared: %s", line)
		}

		// Look for the tunnel URL
		if match := tunnelURLPattern.FindString(line); match != "" {
			t.once.Do(func() {
				t.url = match
				close(t.ready)
			})
		}
	}
}

// URL returns the tunnel URL (empty if not yet ready).
func (t *Tunnel) URL() string {
	return t.url
}

// Kill terminates the cloudflared process.
func (t *Tunnel) Kill() {
	if t.cmd != nil && t.cmd.Process != nil {
		t.cmd.Process.Kill()
	}
}

// Wait blocks until the tunnel process exits.
func (t *Tunnel) Wait() {
	<-t.stopped
}

// PrintBanner prints the startup banner with local and tunnel URLs.
func PrintBanner(listenAddr string, tunnelURL string, models []string) {
	// Normalize listen address for display
	localAddr := listenAddr
	if strings.HasPrefix(localAddr, ":") {
		localAddr = "localhost" + localAddr
	}

	fmt.Println()
	fmt.Println("══════════════════════════════════════════════════════════════════════")
	fmt.Println("  🚀 Freebuff2API Server is Live!")
	fmt.Println("══════════════════════════════════════════════════════════════════════")
	fmt.Printf("  • Local URL:      http://%s/v1\n", localAddr)

	if tunnelURL != "" {
		publicURL := tunnelURL + "/v1"
		fmt.Printf("  • Public BaseURL: %s\n", publicURL)
	}

	if len(models) > 0 {
		display := models
		if len(display) > 8 {
			display = display[:8]
		}
		fmt.Printf("  • Target Models:  %s\n", strings.Join(display, ", "))
		if len(models) > 8 {
			fmt.Printf("                   ... and %d more\n", len(models)-8)
		}
	}

	fmt.Println()
	fmt.Println("  📋 Sample Usage:")

	sampleURL := fmt.Sprintf("http://%s/v1/chat/completions", localAddr)
	if tunnelURL != "" {
		sampleURL = tunnelURL + "/v1/chat/completions"
	}

	fmt.Printf("  curl %s \\\n", sampleURL)
	fmt.Println(`    -H "Content-Type: application/json" \`)
	fmt.Println(`    -H "Authorization: Bearer any-key" \`)
	fmt.Println(`    -d '{"model": "deepseek-chat", "messages": [{"role": "user", "content": "Hello!"}]}'`)
	fmt.Println("══════════════════════════════════════════════════════════════════════")
	fmt.Println()
}
