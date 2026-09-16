// Package api (enginecache_route_test.go): proves
// RegisterEngineCacheRoute's real POST /v1/replication/enginecache
// receiving side (T016, 003-kv-cache-replication User Story 2) over a
// real HTTP/3+mTLS round trip, mirroring
// routes_replication_test.go's exact bootstrap pattern - a real
// *raft.Node, a real *Server, real JWT tokens, no mocked transport.
package api

import (
	"bytes"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/vasic-digital/llmctl/llmctld/internal/mtls"
	"github.com/vasic-digital/llmctl/llmctld/internal/raft"
)

// newFixedReader returns a fresh io.Reader over data - used instead of
// sharing one bytes.Reader across requests (a bytes.Reader is
// single-use/stateful once read).
func newFixedReader(data []byte) io.Reader { return bytes.NewReader(data) }

func bootstrapEngineCacheTestServer(t *testing.T, cacheDirs map[string]string) (client *http.Client, apiAddr, tenantAToken, tenantBToken string) {
	t.Helper()
	ca, err := mtls.GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA: %v", err)
	}
	node, err := raft.Bootstrap(raft.Config{
		NodeID:    "node-a",
		BindAddr:  "127.0.0.1:0",
		TLSConfig: buildTestTLSConfig(t, ca, "node-a"),
	})
	if err != nil {
		t.Fatalf("raft.Bootstrap: %v", err)
	}
	t.Cleanup(func() { _ = node.Shutdown() })
	waitForRealLeader(t, node, 3*time.Second)

	decider := newReplicationTestDecider()
	srv := NewServer(node, buildTestTLSConfig(t, ca, "node-a-api"))
	RegisterEngineCacheRoute(srv.Router(), decider, func(tenantID string) (string, bool) {
		dir, ok := cacheDirs[tenantID]
		return dir, ok
	})
	if err := srv.Listen("127.0.0.1:0"); err != nil {
		t.Fatalf("Listen: %v", err)
	}
	t.Cleanup(func() { _ = srv.Close() })

	client = newTestClient(buildTestTLSConfig(t, ca, "test-client"))
	apiAddr = srv.Addr
	tenantAToken = issueReplicationTestJWT(t, decider, "tenant-a")
	tenantBToken = issueReplicationTestJWT(t, decider, "tenant-b")
	return client, apiAddr, tenantAToken, tenantBToken
}

func TestEngineCacheRoute_UploadsRealBytesToTheConfiguredDirectory(t *testing.T) {
	destDir := t.TempDir()
	client, apiAddr, tenantAToken, _ := bootstrapEngineCacheTestServer(t, map[string]string{"tenant-a": destDir})

	req, err := http.NewRequest(http.MethodPost, "https://"+apiAddr+"/v1/replication/enginecache", newFixedReader([]byte("genuine engine-produced slot bytes")))
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer "+tenantAToken)
	req.Header.Set(tenantIDHeader, "tenant-a")
	req.Header.Set(engineCacheFilenameHeader, "tenant-a.bin")
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("POST /v1/replication/enginecache: %v", err)
	}
	body, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200, body = %s", resp.StatusCode, body)
	}

	got, err := os.ReadFile(filepath.Join(destDir, "tenant-a.bin"))
	if err != nil {
		t.Fatalf("read uploaded file: %v", err)
	}
	if string(got) != "genuine engine-produced slot bytes" {
		t.Fatalf("uploaded file content = %q, want the real posted bytes", got)
	}
}

func TestEngineCacheRoute_CrossTenantUpload_Denied(t *testing.T) {
	destDir := t.TempDir()
	client, apiAddr, _, tenantBToken := bootstrapEngineCacheTestServer(t, map[string]string{"tenant-a": destDir})

	req, err := http.NewRequest(http.MethodPost, "https://"+apiAddr+"/v1/replication/enginecache", newFixedReader([]byte("attempted leak")))
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer "+tenantBToken)
	req.Header.Set(tenantIDHeader, "tenant-a")
	req.Header.Set(engineCacheFilenameHeader, "leak.bin")
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("POST /v1/replication/enginecache: %v", err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("cross-tenant upload attempt: status = %d, want 403", resp.StatusCode)
	}
	if _, err := os.Stat(filepath.Join(destDir, "leak.bin")); err == nil {
		t.Fatalf("cross-tenant upload was denied but the file was written anyway - a real data-leak defect")
	}
}

func TestEngineCacheRoute_PathLikeFilename_RefusedBeforeAnyWrite(t *testing.T) {
	destDir := t.TempDir()
	client, apiAddr, tenantAToken, _ := bootstrapEngineCacheTestServer(t, map[string]string{"tenant-a": destDir})

	req, err := http.NewRequest(http.MethodPost, "https://"+apiAddr+"/v1/replication/enginecache", newFixedReader([]byte("x")))
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer "+tenantAToken)
	req.Header.Set(tenantIDHeader, "tenant-a")
	req.Header.Set(engineCacheFilenameHeader, "../escape.bin")
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("POST /v1/replication/enginecache: %v", err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("path-like filename: status = %d, want 400", resp.StatusCode)
	}
}

func TestEngineCacheRoute_NoDirectoryConfiguredForTenant_HonestServiceUnavailable(t *testing.T) {
	client, apiAddr, tenantAToken, _ := bootstrapEngineCacheTestServer(t, map[string]string{})

	req, err := http.NewRequest(http.MethodPost, "https://"+apiAddr+"/v1/replication/enginecache", newFixedReader([]byte("x")))
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer "+tenantAToken)
	req.Header.Set(tenantIDHeader, "tenant-a")
	req.Header.Set(engineCacheFilenameHeader, "x.bin")
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("POST /v1/replication/enginecache: %v", err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("unconfigured tenant: status = %d, want 503 (honest, never a silent 200)", resp.StatusCode)
	}
}
