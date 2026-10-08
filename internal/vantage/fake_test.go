package vantage

import (
	"context"
	"errors"
	"io"
	"strings"
	"sync"

	"digital.vasic.containers/pkg/runtime"
)

// fakeRT is a UNIT-TIER fake of the Containers submodule's ContainerRuntime
// (§11.4.27: fakes are permitted only in unit tests; tests/test_vantage.sh
// exercises the real thing).
type fakeRT struct {
	mu          sync.Mutex
	unavailable bool
	missing     map[string]bool // images "not present locally"
	runs        [][]string      // recorded images + argv
	runOpts     [][]runtime.RunOption
	containers  map[string]runtime.ContainerState
	labels      map[string]map[string]string // container name -> labels (from --label k=v of Run, or set by a test)
	execCmds    [][]string                   // every Exec argv
	execOut     map[string]string            // command word -> stdout
	execExit    int
	removeErr   error
	stopped     []string
	removed     []string
	listErr     error
}

func newFake() *fakeRT {
	return &fakeRT{missing: map[string]bool{}, containers: map[string]runtime.ContainerState{}, labels: map[string]map[string]string{}, execOut: map[string]string{
		"info": `{"addrs":["10.0.2.100"],"routes":[],"default_gateway":"10.0.2.2"}`,
	}}
}

func (f *fakeRT) Name() string                                                { return "fake" }
func (f *fakeRT) Version(context.Context) (string, error)                     { return "0", nil }
func (f *fakeRT) IsAvailable(context.Context) bool                            { return !f.unavailable }
func (f *fakeRT) Start(context.Context, string, ...runtime.StartOption) error { return nil }
func (f *fakeRT) Stop(_ context.Context, id string, _ ...runtime.StopOption) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.stopped = append(f.stopped, id)
	return nil
}
func (f *fakeRT) Remove(_ context.Context, id string, _ ...runtime.RemoveOption) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.removed = append(f.removed, id)
	if f.removeErr != nil {
		return f.removeErr
	}
	delete(f.containers, id)
	delete(f.labels, id)
	return nil
}
func (f *fakeRT) Status(context.Context, string) (*runtime.ContainerStatus, error) {
	return nil, errors.New("n/a")
}
func (f *fakeRT) List(_ context.Context, fl runtime.ListFilter) ([]runtime.ContainerInfo, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.listErr != nil {
		return nil, f.listErr
	}
	var out []runtime.ContainerInfo
	for n, st := range f.containers {
		match := len(fl.Names) == 0 && len(fl.Labels) == 0
		for _, w := range fl.Names {
			if w == n {
				match = true
			}
		}
		if len(fl.Labels) > 0 {
			match = true
			for k, v := range fl.Labels { // a label filter matches only containers carrying every pair
				if f.labels[n][k] != v {
					match = false
				}
			}
		}
		if match && (fl.All || st == runtime.StateRunning) {
			out = append(out, runtime.ContainerInfo{Name: "/" + n, State: st})
		}
	}
	return out, nil
}
func (f *fakeRT) Stats(context.Context, string) (*runtime.ContainerStats, error) {
	return nil, errors.New("n/a")
}
func (f *fakeRT) Exec(_ context.Context, id string, cmd []string) (*runtime.ExecResult, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if _, ok := f.containers[id]; !ok {
		return nil, errors.New("no such container")
	}
	f.execCmds = append(f.execCmds, append([]string(nil), cmd...))
	for _, w := range cmd {
		if out, ok := f.execOut[w]; ok {
			return &runtime.ExecResult{ExitCode: f.execExit, Stdout: out}, nil
		}
	}
	return &runtime.ExecResult{ExitCode: f.execExit, Stdout: "{}"}, nil
}
func (f *fakeRT) Run(_ context.Context, image string, cmd []string, opts ...runtime.RunOption) (*runtime.ExecResult, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.runs = append(f.runs, append([]string{image}, cmd...))
	f.runOpts = append(f.runOpts, opts)
	if f.missing[image] {
		return &runtime.ExecResult{ExitCode: 125, Stderr: "Error: " + image + ": image not known"}, nil
	}
	spec := runtime.ResolveRunSpec(image, cmd, opts)
	name := ""
	for i, a := range spec.Args {
		if a == "--name" {
			name = spec.Args[i+1]
		}
	}
	f.containers[name] = runtime.StateRunning
	f.labels[name] = map[string]string{}
	for i, a := range spec.Args {
		if a == "--label" && i+1 < len(spec.Args) {
			if k, v, ok := strings.Cut(spec.Args[i+1], "="); ok {
				f.labels[name][k] = v
			}
		}
	}
	return &runtime.ExecResult{Stdout: "deadbeef\n"}, nil
}
func (f *fakeRT) Logs(context.Context, string, ...runtime.LogOption) (io.ReadCloser, error) {
	return nil, errors.New("n/a")
}

func (f *fakeRT) lastArgs() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.runs) == 0 {
		return nil
	}
	return runtime.ResolveRunSpec(f.runs[len(f.runs)-1][0], f.runs[len(f.runs)-1][1:], f.runOpts[len(f.runOpts)-1]).Args
}
