package vantage

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCorruptStateIsReportedNotIgnored(t *testing.T) {
	m := newMgr(t, newFake())
	os.MkdirAll(filepath.Join(m.o.StateDir, "vantage"), 0o700)
	os.WriteFile(filepath.Join(m.o.StateDir, "vantage", "state.json"), []byte("{broken"), 0o600)
	if _, err := m.Load(); err == nil {
		t.Fatal("corrupt state must be an error")
	}
	if _, err := m.Up(context.Background()); err == nil {
		t.Fatal("up must not paper over corrupt state")
	}
}

func TestStageProbeUsesInjectedBuilderAndRefusesFailure(t *testing.T) {
	built := 0
	m := newMgr(t, newFake(), func(o *Options) {
		o.ProbeBin = ""
		o.BuildProbe = func(_ context.Context, dir string) (string, error) {
			built++
			return BuildProbe(context.Background(), dir)
		}
	})
	t.Setenv("LLMCTL_VANTAGE_PROBE", "")
	if _, err := m.Up(context.Background()); err != nil || built != 1 {
		t.Fatalf("built=%d err=%v", built, err)
	}
	m2 := newMgr(t, newFake(), func(o *Options) {
		o.ProbeBin = ""
		o.BuildProbe = func(context.Context, string) (string, error) { return "", errors.New("no go") }
	})
	if _, err := m2.Up(context.Background()); err == nil || !strings.Contains(err.Error(), "no probe binary") {
		t.Fatalf("%v", err)
	}
}

func TestDefaultImagesHonourEnvAndExistsReportsListFailure(t *testing.T) {
	t.Setenv("LLMCTL_VANTAGE_IMAGE", "my/img:1")
	if d := DefaultImages(); d[0] != "my/img:1" || len(d) < 3 {
		t.Fatalf("%v", d)
	}
	f := newFake()
	f.listErr = errors.New("podman gone")
	m := newMgr(t, f)
	if !m.exists(context.Background(), NamePrefix+"x") {
		t.Fatal("when listing fails we cannot claim absence")
	}
	if m.running(context.Background(), NamePrefix+"x") {
		t.Fatal("when listing fails we cannot claim running")
	}
	if firstOr(nil) != "" || firstLine("a\nb") != "a" {
		t.Fatal("helpers")
	}
}
