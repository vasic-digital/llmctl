package gateway

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strconv"

	"github.com/vasic-digital/llmctl/internal/contract"
)

// templateHashVersion is bumped when the SHAPE of the hashed document changes (never for a prompt
// edit - a prompt edit changes the rendered text and so the hash by itself).
const templateHashVersion = "llmctl-decide-template/1"

// canonical inputs the template is rendered with. They are fixed strings, so the rendered document
// is a pure function of the template code and the readout parameters, never of any request.
const (
	canonState = "TEMPLATE-STATE"
	canonInstr = "TEMPLATE-INSTRUCTIONS"
)

func canonQuestion() contract.ParsedQuestion {
	return contract.ParsedQuestion{Name: "q", Type: contract.TypeChoice, Instructions: canonInstr,
		Options: []contract.Option{{Letter: "A", Key: "a", Label: "TEMPLATE-OPTION-A"}, {Letter: "B", Key: "b", Label: "TEMPLATE-OPTION-B"}}}
}

// TemplateHash is the `decision.template_hash` of a profile: the lowercase-hex SHA-256 of a
// canonical document that holds everything that decides what probabilities a model produces for
// a given state and question, EXCEPT the model file itself (that is bound separately by its own
// checksum). Exactly what is hashed, per protocol:
//
//   - letter-logit: the template version tag, the protocol, the prompt the gateway really sends
//     (contract.RenderPrompt of a fixed canonical question and state - header, state delimiters,
//     question line, option lines, answer instruction), the readout spellings (JSON, in order),
//     n_probs, and the effective global readout temperature (LLMCTL_DECIDE_TEMPERATURE; 0 or
//     unset means 1, formatted by strconv 'g' -1). The mass threshold and cache_prompt are NOT
//     hashed: they decide whether an answer exists and how fast, not the value of its probabilities.
//   - systemone-native: the version tag, the protocol, and the hosted-shape request body the
//     gateway forwards (nativeBody of a fixed canonical request with one noul, one choice and one
//     score question, so the criteria encoding is covered). The engine renders its own prompt; the
//     engine build is covered by the model checksum binding.
//   - nli-onnx: the version tag, the protocol, the premise/hypothesis construction
//     (DefaultHypothesis of the canonical question and option, the premise being the cleaned state
//     as-is) and the scorer endpoint/column convention.
//
// A profile id never enters the hash, so profiles sharing a template share it. An unknown protocol
// is an error.
func TemplateHash(spec ProfileSpec, temperature float64) (string, error) {
	doc, err := templateDocument(spec, temperature)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256([]byte(doc))
	return hex.EncodeToString(sum[:]), nil
}

func templateDocument(spec ProfileSpec, temperature float64) (string, error) {
	q := canonQuestion()
	switch spec.Protocol {
	case ProtoLetter:
		prompt, err := contract.RenderPrompt(q, canonState)
		if err != nil {
			return "", err
		}
		sp, _ := json.Marshal(spec.Readout.Spellings)
		if temperature <= 0 {
			temperature = 1
		}
		return fmt.Sprintf("%s\nprotocol=%s\ntemperature=%s\nn_probs=%d\nspellings=%s\nprompt=%s\n",
			templateHashVersion, ProtoLetter, fmtFloat(temperature), spec.Readout.NProbs, sp, prompt), nil
	case ProtoNative:
		req := &contract.ParsedRequest{Model: "template", StateText: canonState, Questions: []contract.ParsedQuestion{
			{Name: "n", Type: contract.TypeNoul, Instructions: canonInstr,
				Options: []contract.Option{{Key: "yes", Label: "yes"}, {Key: "no", Label: "no"}}},
			q,
			{Name: "s", Type: contract.TypeScore, Instructions: canonInstr,
				Options: []contract.Option{{Key: "0", Label: "0 - TEMPLATE-LEVEL-0"}, {Key: "1", Label: "1 - TEMPLATE-LEVEL-1"}},
				Legend:  []contract.LegendEntry{{Key: "0", Value: json.RawMessage(`"TEMPLATE-LEVEL-0"`)}, {Key: "1", Value: json.RawMessage(`"TEMPLATE-LEVEL-1"`)}}},
		}}
		body, err := nativeBody("template", req)
		if err != nil {
			return "", err
		}
		return fmt.Sprintf("%s\nprotocol=%s\nbody=%s\n", templateHashVersion, ProtoNative, body), nil
	case ProtoNLI:
		o := q.Options[0]
		return fmt.Sprintf("%s\nprotocol=%s\nendpoint=/v1/score\ncolumn=entailment\npremise=%s\nhypothesis=%s\n",
			templateHashVersion, ProtoNLI, canonState, DefaultHypothesis(q, o)), nil
	}
	return "", fmt.Errorf("gateway: template hash: unknown decision protocol %q", spec.Protocol)
}

// ErrNoModelSHA and ErrManyModelSHA classify a catalog profile whose live model checksum cannot be
// named: no model file with a lowercase-hex sha256, or more than one model file.
var (
	ErrNoModelSHA   = errors.New("gateway: the catalog entry has no model file with a sha256")
	ErrManyModelSHA = errors.New("gateway: the catalog entry lists more than one model file")
)

var modelSHARe = regexp.MustCompile(`^[0-9a-f]{64}$`)

// SingleModelSHA picks THE model checksum from the sha256 values of a profile's files[role=model]:
// exactly one, 64 lowercase hex characters. It is the one rule `llmctl-decide calibrate` (which
// binds a profile) and the gateway (which decides whether to apply it) both use, so the two can
// never resolve a different "live model".
func SingleModelSHA(shas []string) (string, error) {
	s := append([]string(nil), shas...)
	sort.Strings(s)
	switch {
	case len(s) == 0 || !modelSHARe.MatchString(s[0]):
		return "", ErrNoModelSHA
	case len(s) > 1:
		return "", ErrManyModelSHA
	}
	return s[0], nil
}

func fmtFloat(f float64) string { return strconv.FormatFloat(f, 'g', -1, 64) }
