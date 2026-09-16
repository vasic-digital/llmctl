// Command llmctld (hardware_probe.go): sources the joining node's own
// real capacity for the extended POST /v1/cluster/join request body
// (002-cluster-model-scheduler T006, contracts/cluster-model-api.md's
// "resources" field), never a guessed or zero-value placeholder.
//
// Real CLI surface this shells out to (confirmed by reading bin/llmctl's
// dispatch `case` statement and lib/hardware.sh directly, 2026-09-16 -
// never assumed):
//
//	hw --json    -> bin/llmctl case "hw) if [[ "${1:-}" == "--json" ]];
//	                then hw_probe_json; else hw_probe_human; fi ;;"
//	             -> lib/hardware.sh's hw_probe_json, a python3 heredoc
//	                emitting {"cpu":{"cores":N,...},
//	                "memory":{"total_mb":N,"available_mb":N},
//	                "gpus":[...],"gpu_total_vram_mb":N,"storage":{...}}
//
// There is no separate "hardware probe --json" subcommand - that shape
// was this task's own initial (unconfirmed) guess; the real, existing
// subcommand is the bare `hw` command with a `--json` flag, exactly as
// internal/executor/local.go's own doc comment discipline requires
// (confirm the real CLI surface by reading the bash source, never assume
// a plausible-sounding one).
package main

import (
	"encoding/json"
	"fmt"
	"os/exec"

	"github.com/vasic-digital/llmctl/llmctld/internal/cluster"
)

// hwProbeDoc is the subset of hw_probe_json's real JSON schema this node
// needs to populate cluster.Resources - every other field (os, arch,
// cpu.model, cpu.simd, cpu.apple_silicon, gpus[], storage) is real output
// this node does not currently need, so it is left unparsed rather than
// invented into a Resources field that has no corresponding probe data.
type hwProbeDoc struct {
	CPU struct {
		Cores int `json:"cores"`
	} `json:"cpu"`
	Memory struct {
		TotalMB     int64 `json:"total_mb"`
		AvailableMB int64 `json:"available_mb"`
	} `json:"memory"`
	GPUTotalVRAMMB int64 `json:"gpu_total_vram_mb"`
}

// probeLocalResources shells out to the real `<llmctlPath> hw --json`
// (llmctlPath empty resolves to the bare "llmctl" name via $PATH,
// matching internal/executor.Config.LLMCtlPath's own documented default)
// and converts its real output into a cluster.Resources value.
//
// gpu_total_vram_mb is reported as BOTH VRAMTotalMB and VRAMAvailMB: the
// hardware probe reports raw hardware CAPACITY (matching
// cluster.Resources's own doc comment - "this node's total capacity, as
// reported by its local hardware probe"), not live in-use VRAM
// consumption, so at join time (before this node is running any model)
// its full VRAM capacity is genuinely available; subsequent
// CommandUpdateResources heartbeats (T008) are what keep RAMAvailMB/
// VRAMAvailMB current as this node's own models start consuming budget.
// network_mbps has no corresponding hw_probe_json field at all, so it is
// honestly left at its zero value rather than invented.
func probeLocalResources(llmctlPath string) (cluster.Resources, error) {
	path := llmctlPath
	if path == "" {
		path = "llmctl"
	}

	cmd := exec.Command(path, "hw", "--json")
	out, err := cmd.Output()
	if err != nil {
		return cluster.Resources{}, fmt.Errorf("probe local hardware via %q hw --json: %w", path, err)
	}

	var doc hwProbeDoc
	if err := json.Unmarshal(out, &doc); err != nil {
		return cluster.Resources{}, fmt.Errorf("parse hardware probe JSON from %q hw --json: %w", path, err)
	}

	return cluster.Resources{
		CPUCores:    doc.CPU.Cores,
		RAMTotalMB:  doc.Memory.TotalMB,
		RAMAvailMB:  doc.Memory.AvailableMB,
		VRAMTotalMB: doc.GPUTotalVRAMMB,
		VRAMAvailMB: doc.GPUTotalVRAMMB,
	}, nil
}
