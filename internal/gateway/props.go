package gateway

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"
)

// The per-slot context an engine really serves can differ from the catalog default: the launcher
// honours LLMCTL_CTX_<PROFILE> (lib/catalog.sh resolve_ctx) and the gateway may not have seen the
// same environment (review-3 B2-05, G-093). llama-server reports the effective per-slot context in
// GET /props -> default_generation_settings.n_ctx; the gateway prefers that value and falls back to
// the configured one (catalog default + LLMCTL_CTX_<PROFILE>) when /props is not available.

const (
	propsTTL         = 10 * time.Second // short: an engine restarted with another ctx is noticed quickly
	propsNegativeTTL = 5 * time.Second
	propsTimeout     = 1500 * time.Millisecond
	propsMaxEntries  = 256 // the cache is keyed by URL: bounded so a changing port set cannot grow it
)

type propsEntry struct {
	n   int // 0 = unavailable
	exp time.Time
}

// propsCall is one in-flight fetch shared by every concurrent miss for the same URL.
type propsCall struct {
	done chan struct{}
	n    int
}

var (
	propsMu       sync.Mutex
	propsCache    = map[string]propsEntry{}
	propsInflight = map[string]*propsCall{}
	propsNow      = time.Now
)

// invalidateProps forgets what is known of an endpoint's context. The completion path calls it when
// the engine answers a request with an error or cannot be reached: the process behind the URL may
// have been restarted with another context, so the cached value is not trusted any more (B3-04).
func invalidateProps(url string) {
	propsMu.Lock()
	delete(propsCache, url)
	propsMu.Unlock()
}

// engineCtx returns the per-slot context the engine at ep reports, or (0, false) when it does not
// (no /props, not llama-server, unreachable, malformed). Results are cached per endpoint URL (a
// bounded map, short TTL), concurrent misses share ONE fetch, and the fetch is detached from the
// requesting context so a cancelled request neither poisons the cache nor aborts the others (B3-04).
func engineCtx(ctx context.Context, hc *http.Client, ep Endpoint) (int, bool) {
	now := propsNow()
	propsMu.Lock()
	if e, ok := propsCache[ep.URL]; ok && now.Before(e.exp) {
		propsMu.Unlock()
		return e.n, e.n > 0
	}
	if c, ok := propsInflight[ep.URL]; ok {
		propsMu.Unlock()
		select {
		case <-c.done:
			return c.n, c.n > 0
		case <-ctx.Done():
			return 0, false
		}
	}
	c := &propsCall{done: make(chan struct{})}
	propsInflight[ep.URL] = c
	propsMu.Unlock()

	n := fetchProps(context.WithoutCancel(ctx), hc, ep)
	ttl := propsTTL
	if n <= 0 {
		ttl = propsNegativeTTL
	}
	propsMu.Lock()
	delete(propsInflight, ep.URL)
	prunePropsLocked(now)
	propsCache[ep.URL] = propsEntry{n: n, exp: now.Add(ttl)}
	propsMu.Unlock()
	c.n = n
	close(c.done)
	return n, n > 0
}

// prunePropsLocked drops expired entries and, while the map is still full, arbitrary ones.
func prunePropsLocked(now time.Time) {
	if len(propsCache) < propsMaxEntries {
		return
	}
	for k, e := range propsCache {
		if !now.Before(e.exp) {
			delete(propsCache, k)
		}
	}
	for k := range propsCache {
		if len(propsCache) < propsMaxEntries {
			break
		}
		delete(propsCache, k)
	}
}

func fetchProps(ctx context.Context, hc *http.Client, ep Endpoint) int {
	if checkLoopback(ep.URL) != nil {
		return 0
	}
	if hc == nil {
		hc = sharedClient
	}
	if hc.CheckRedirect == nil {
		c := *hc
		c.CheckRedirect = noRedirect
		hc = &c
	}
	ctx, cancel := context.WithTimeout(ctx, propsTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(ep.URL, "/")+"/props", nil)
	if err != nil {
		return 0
	}
	if ep.Key != "" {
		req.Header.Set("Authorization", "Bearer "+ep.Key)
	}
	resp, err := hc.Do(req)
	if err != nil {
		return 0
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 0
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return 0
	}
	var doc struct {
		Gen struct {
			NCtx float64 `json:"n_ctx"`
		} `json:"default_generation_settings"`
	}
	if json.Unmarshal(b, &doc) != nil || doc.Gen.NCtx < 16 || doc.Gen.NCtx > 1<<24 || doc.Gen.NCtx != float64(int(doc.Gen.NCtx)) {
		return 0
	}
	return int(doc.Gen.NCtx)
}
