package main

import (
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
