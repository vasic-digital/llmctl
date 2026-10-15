package main

import (
	"bytes"
	"strings"
	"testing"

	"github.com/vasic-digital/llmctl/internal/gateway"
)

// Review 2026-10-15 finding 7: in auto mode a profile WITHOUT a healthy registry row used to be routed to its catalog
// port (static fallback) - an engine llmctl never validated, or one it withdrew, was a backend. Under the strict
// validation gate (the default) only an operator-declared LLMCTL_DECIDE_ENDPOINT_<P> is; LLMCTL_VALIDATE_STRICT=0 restores
// the catalog-port fallback.
func resolveTiny(t *testing.T, se *serveEnvT) []gateway.Endpoint {
	t.Helper()
	p := prep(t, se)
	res, err := p.buildResolver(p.specs)
	if err != nil {
		t.Fatal(err)
	}
	eps, _ := res.Resolve(gateway.KindDecide, "decide-tiny")
	return eps
}

func TestF7AutoStrictDoesNotRouteAnUnregisteredProfile(t *testing.T) {
	se := setupServeEnv(t)
	if eps := resolveTiny(t, se); len(eps) != 0 {
		t.Fatalf("strict (default): an unregistered profile must have no backend, got %+v", eps)
	}
}

func TestF7AutoStrictKeepsAnOperatorDeclaredEndpoint(t *testing.T) {
	se := setupServeEnv(t)
	se.env[gateway.EndpointVar("decide-tiny")] = "http://127.0.0.1:18123"
	eps := resolveTiny(t, se)
	if len(eps) != 1 || eps[0].URL != "http://127.0.0.1:18123" {
		t.Fatalf("a declared LLMCTL_DECIDE_ENDPOINT_<P> stays routable, got %+v", eps)
	}
}

func TestF7AutoNonStrictKeepsTheCatalogPortFallback(t *testing.T) {
	se := setupServeEnv(t)
	se.env["LLMCTL_VALIDATE_STRICT"] = "0"
	if eps := resolveTiny(t, se); len(eps) != 1 {
		t.Fatalf("LLMCTL_VALIDATE_STRICT=0 (control): the catalog-port fallback applies, got %+v", eps)
	}
}

func TestF7StaticModeIsTheOperatorsChoice(t *testing.T) {
	se := setupServeEnv(t)
	se.env[resolverVar] = "static"
	if eps := resolveTiny(t, se); len(eps) != 1 {
		t.Fatalf("mode=static keeps its full table, got %+v", eps)
	}
}

// Review 3 of 2026-10-15, finding 8: a whitespace- or comma-only LLMCTL_DECIDE_ENDPOINT_<P> counted as "declared" but
// yielded no URL, so the catalog-port fallback finding 7 removed came back through StaticResolverFromEnv. A profile is
// declared only when at least one non-empty URL remains.
func TestF7AutoStrictBlankDeclarationIsNotADeclaration(t *testing.T) {
	for _, v := range []string{" ", ",", " , ,\t", ",,"} {
		se := setupServeEnv(t)
		se.env[gateway.EndpointVar("decide-tiny")] = v
		if eps := resolveTiny(t, se); len(eps) != 0 {
			t.Fatalf("strict: LLMCTL_DECIDE_ENDPOINT_DECIDE_TINY=%q declares no URL, yet the profile routes to %+v", v, eps)
		}
	}
}

func TestF7AutoStrictMixedDeclarationKeepsOnlyRealURLs(t *testing.T) {
	se := setupServeEnv(t)
	se.env[gateway.EndpointVar("decide-tiny")] = " , http://127.0.0.1:18124 ,"
	eps := resolveTiny(t, se)
	if len(eps) != 1 || eps[0].URL != "http://127.0.0.1:18124" {
		t.Fatalf("only the declared URL is routable, got %+v", eps)
	}
}

// Review 3 of 2026-10-15, finding 8: mode=static routes to catalog ports without the validation gate - it stays the
// operator's choice, but it says so on stderr at startup.
func TestF7StaticModeWarnsThatItBypassesTheGate(t *testing.T) {
	se := setupServeEnv(t)
	se.env[resolverVar] = "static"
	var e bytes.Buffer
	p, code := prepare(serveFlags{port: 9}, se.env, resolveDirs(se.env), &e)
	if p == nil {
		t.Fatalf("prepare rc=%d err=%s", code, e.String())
	}
	t.Cleanup(p.close)
	if !strings.Contains(e.String(), "LLMCTL_DECIDE_RESOLVER=static") || !strings.Contains(e.String(), "not validated") {
		t.Fatalf("static mode must warn that it routes to unvalidated engines on catalog ports; stderr: %q", e.String())
	}
}

func TestF7AutoModeDoesNotWarnAboutStatic(t *testing.T) {
	se := setupServeEnv(t)
	var e bytes.Buffer
	p, code := prepare(serveFlags{port: 9}, se.env, resolveDirs(se.env), &e)
	if p == nil {
		t.Fatalf("prepare rc=%d err=%s", code, e.String())
	}
	t.Cleanup(p.close)
	if strings.Contains(e.String(), "LLMCTL_DECIDE_RESOLVER=static") {
		t.Fatalf("control: the default mode prints no static-mode warning; stderr: %q", e.String())
	}
}
