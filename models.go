package main

import (
	"context"
	"fmt"
	"io"
	"log"
	"math/rand/v2"
	"net/http"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	freeAgentsSourceURL  = "https://raw.githubusercontent.com/CodebuffAI/codebuff/main/common/src/constants/free-agents.ts"
	modelRefreshInterval = 15 * time.Minute
)

// hardcodedFallback is the canonical model→agent mapping sourced from the
// upstream codebuff/common/src/constants/free-agents.ts. Wire IDs are exact
// (e.g. "z-ai/glm-5.2", "openai/gpt-5.6-luna") — the upstream's
// isFreeModeAllowedAgentModel does an exact Set.has(model) check, so a bare
// slug will 403 with free_mode_invalid_agent_model even on the right agent.
//
// We use base3 roots for new free sessions (per docs/freebuff-base3-harness.md):
// base2 is the older harness kept for already-admitted sessions and the
// FREEBUFF_BASE3_HARNESS_DISABLED kill switch.
var hardcodedFallback = map[string][]string{
	"base3-free-deepseek-flash":   {"deepseek/deepseek-v4-flash"},
	"base3-free-deepseek":         {"deepseek/deepseek-v4-pro"},
	"base3-free-mimo":             {"mimo/mimo-v2.5"},
	"base3-free-minimax-m3":       {"minimax/minimax-m3"},
	"base3-free-luna":             {"openai/gpt-5.6-luna"},
	"base3-free-solar-pro4":       {"upstage/solar-pro4"},
	"base3-free-glm":              {"z-ai/glm-5.2"},
	"base3-free-glm-5-3-flash":    {"z-ai/glm-5.3-flash"},
	"base3-free-kimi-k3-eco":      {"crof/kimi-k3-eco"},
	"base3-free-fable":            {"anthropic/claude-fable-5"},
	"base3-free-ox-alpha":         {"stealth/ox-alpha"},
	"file-picker":                 {"google/gemini-3.5-flash-lite", "google/gemini-3.1-flash-lite"},
}

// ModelRegistry fetches and caches the agent→model mapping for all free agents
// from the upstream free-agents.ts source file.
type ModelRegistry struct {
	client *http.Client
	logger *log.Logger

	mu           sync.RWMutex
	agentModels  map[string][]string // agentID → []model
	modelToAgent map[string]string   // model → chosen agentID
	allModels    []string            // deduplicated, sorted
	lastOK       time.Time

	stopCh chan struct{}
	wg     sync.WaitGroup
}

func NewModelRegistry(client *http.Client, logger *log.Logger) *ModelRegistry {
	return &ModelRegistry{
		client:       client,
		logger:       logger,
		agentModels:  make(map[string][]string),
		modelToAgent: make(map[string]string),
		stopCh:       make(chan struct{}),
	}
}

func (r *ModelRegistry) Start(ctx context.Context) {
	if err := r.refresh(ctx); err != nil {
		r.logger.Printf("model registry: initial fetch failed, loading hardcoded fallback: %v", err)
		r.loadFallback()
	}

	r.wg.Add(1)
	go func() {
		defer r.wg.Done()
		ticker := time.NewTicker(modelRefreshInterval)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
				if err := r.refresh(ctx); err != nil {
					r.logger.Printf("model registry: refresh failed: %v", err)
				}
				cancel()
			case <-r.stopCh:
				return
			}
		}
	}()
}

func (r *ModelRegistry) Stop() {
	close(r.stopCh)
	r.wg.Wait()
}

// Models returns the deduplicated list of all available model names.
func (r *ModelRegistry) Models() []string {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]string, len(r.allModels))
	copy(out, r.allModels)
	return out
}

// HasModel checks if the given model is available.
func (r *ModelRegistry) HasModel(model string) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	_, ok := r.modelToAgent[model]
	return ok
}

// AgentForModel returns the agent ID that should serve the given model.
func (r *ModelRegistry) AgentForModel(model string) (string, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	agent, ok := r.modelToAgent[model]
	return agent, ok
}

// DefaultAgentID returns the preferred agent ID for permissive routing when
// a requested model has no explicit mapping. Prefers base3-free-deepseek-flash
// (the Freebuff CLI's default picker root per the FAQ) and falls back to any
// other known base3 root. Never falls back to legacy "base2-free" — that
// allowlist covers 5 models and rejects everything else.
func (r *ModelRegistry) DefaultAgentID() string {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if _, ok := r.agentModels["base3-free-deepseek-flash"]; ok {
		return "base3-free-deepseek-flash"
	}
	for id := range r.agentModels {
		return id
	}
	return "base3-free-deepseek-flash"
}

// AgentIDs returns the list of all known agent IDs.
func (r *ModelRegistry) AgentIDs() []string {
	r.mu.RLock()
	defer r.mu.RUnlock()
	ids := make([]string, 0, len(r.agentModels))
	for id := range r.agentModels {
		ids = append(ids, id)
	}
	return ids
}

func (r *ModelRegistry) refresh(ctx context.Context) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, freeAgentsSourceURL, nil)
	if err != nil {
		return fmt.Errorf("create request: %w", err)
	}
	req.Header.Set("Accept", "text/plain")

	resp, err := r.client.Do(req)
	if err != nil {
		return fmt.Errorf("fetch free-agents source: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("unexpected status %d", resp.StatusCode)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("read response: %w", err)
	}

	remote := parseAllFreeModels(string(body))
	if len(remote) == 0 {
		return fmt.Errorf("no free agents found in source")
	}

	// Merge: keep the local fallback agents (which include the rich set from
	// the Freebuff FAQ) and overlay any agent→model entries from the remote
	// source. Remote wins for shared agent IDs.
	merged := make(map[string][]string, len(hardcodedFallback)+len(remote))
	for id, models := range hardcodedFallback {
		merged[id] = append([]string{}, models...)
	}
	for id, models := range remote {
		merged[id] = append(merged[id], models...)
		// dedupe
		seen := make(map[string]struct{}, len(merged[id]))
		out := merged[id][:0]
		for _, m := range merged[id] {
			if _, ok := seen[m]; ok { continue }
			seen[m] = struct{}{}
			out = append(out, m)
		}
		merged[id] = out
	}

	modelToAgent, allModels := buildModelMapping(merged)

	r.mu.Lock()
	r.agentModels = merged
	r.modelToAgent = modelToAgent
	r.allModels = allModels
	r.lastOK = time.Now()
	r.mu.Unlock()

	r.logger.Printf("model registry: updated %d agents (remote+%d, fallback+%d), %d models", len(merged), len(remote), len(hardcodedFallback), len(allModels))
	return nil
}

func (r *ModelRegistry) loadFallback() {
	modelToAgent, allModels := buildModelMapping(hardcodedFallback)

	r.mu.Lock()
	r.agentModels = hardcodedFallback
	r.modelToAgent = modelToAgent
	r.allModels = allModels
	r.mu.Unlock()

	r.logger.Printf("model registry: loaded fallback models: %v", allModels)
}

// parseAllFreeModels extracts ALL agent→models mappings from the free-agents.ts source.
func parseAllFreeModels(source string) map[string][]string {
	blockPattern := regexp.MustCompile(`'([^']+)':\s*new\s+Set\(\[([^\]]*)\]\)`)
	modelPattern := regexp.MustCompile(`'([^']+)'`)

	result := make(map[string][]string)
	for _, match := range blockPattern.FindAllStringSubmatch(source, -1) {
		agentID := match[1]
		modelsStr := match[2]

		var models []string
		for _, modelMatch := range modelPattern.FindAllStringSubmatch(modelsStr, -1) {
			model := strings.TrimSpace(modelMatch[1])
			if model != "" {
				models = append(models, model)
			}
		}
		if len(models) > 0 {
			result[agentID] = models
		}
	}
	return result
}

// buildModelMapping creates the model→agent reverse mapping and deduplicated model list.
// When a model appears in multiple agents, one is chosen at random.
func buildModelMapping(agentModels map[string][]string) (map[string]string, []string) {
	modelAgents := make(map[string][]string)
	for agentID, models := range agentModels {
		for _, model := range models {
			modelAgents[model] = append(modelAgents[model], agentID)
		}
	}

	modelToAgent := make(map[string]string, len(modelAgents))
	allModels := make([]string, 0, len(modelAgents))
	for model, agents := range modelAgents {
		modelToAgent[model] = agents[rand.IntN(len(agents))]
		allModels = append(allModels, model)
	}
	sort.Strings(allModels)
	return modelToAgent, allModels
}
