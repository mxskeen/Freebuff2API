package main

import (
	"context"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
)

func main() {
	configPath := flag.String("config", "", "path to a JSON config file (default: config.json if present)")
	enableTunnel := flag.Bool("tunnel", false, "start a Cloudflare quick tunnel to expose the server publicly")
	flag.Parse()

	logger := log.New(os.Stdout, "[Freebuff2API] ", log.LstdFlags|log.Lmsgprefix)

	// Auto-detect config.json in CWD when no flag is given
	if *configPath == "" {
		if _, err := os.Stat("config.json"); err == nil {
			*configPath = "config.json"
		}
	}

	// Check environment for tunnel flag
	if !*enableTunnel {
		if v := os.Getenv("ENABLE_TUNNEL"); v == "true" || v == "1" || v == "yes" {
			*enableTunnel = true
		}
	}

	cfg, err := loadConfig(*configPath)
	if err != nil {
		logger.Fatalf("load config: %v", err)
	}

	httpClient := &http.Client{
		Transport: newProxyTransport(cfg.HTTPProxy),
		Timeout:   15 * time.Second,
	}

	registry := NewModelRegistry(httpClient, logger)
	registry.Start(context.Background())
	defer registry.Stop()

	server := NewServer(cfg, logger, registry)
	runCtx, cancelRun := context.WithCancel(context.Background())
	defer cancelRun()
	server.Start(runCtx)

	httpServer := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           server.Handler(),
		ReadHeaderTimeout: 15 * time.Second,
	}

	go func() {
		if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			logger.Fatalf("listen: %v", err)
		}
	}()

	// Wait briefly for the server to bind
	time.Sleep(200 * time.Millisecond)

	// Parse port for tunnel
	port := 8080
	if addr := cfg.ListenAddr; addr != "" {
		if p, err := strconv.Atoi(strings.TrimPrefix(addr, ":")); err == nil {
			port = p
		}
	}

	// Start tunnel if requested
	var tunnel *Tunnel
	var tunnelURL string
	if *enableTunnel {
		tunnel = NewTunnel(port, logger)
		tunnelURL, err = tunnel.Start()
		if err != nil {
			logger.Printf("tunnel: %v (continuing without public URL)", err)
		}
	}

	// Print startup banner
	PrintBanner(cfg.ListenAddr, tunnelURL, registry.Models())

	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM)
	<-signals

	// Clean shutdown
	if tunnel != nil {
		tunnel.Kill()
	}
	shutdownCtx, cancelShutdown := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancelShutdown()

	if err := httpServer.Shutdown(shutdownCtx); err != nil {
		logger.Printf("http shutdown error: %v", err)
	}
	cancelRun()
	server.Shutdown(shutdownCtx)
}
