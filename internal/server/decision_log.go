package server

import (
	"fmt"
	"os"
	"time"

	"github.com/gin-gonic/gin"

	"github.com/vasic-digital/llmctl/internal/audit"
	"github.com/vasic-digital/llmctl/internal/contract"
	"github.com/vasic-digital/llmctl/internal/metrics"
)

// logDecision appends the decision-log record of a request that reached the decision stage (it was
// authenticated and parsed): its status, latency and - when a decision was made - the answer
// summaries. Requests rejected earlier (401, 400, 413, ...) are in the request log only. A write
// failure never fails the request: it is counted (llmctl_decide_audit_write_failures_total, shared
// with the request log) and the first one is reported once on stderr.
func (s *Server) logDecision(c *gin.Context, status int, d time.Duration) {
	if s.cfg.Decisions == nil {
		return
	}
	rv, ok := c.Get(ckDecReq)
	if !ok {
		return
	}
	req := rv.(*contract.ParsedRequest)
	f := audit.DecisionFields{
		RequestID: c.GetString(ckRID), Profile: req.Model, Status: status, Millis: float64(d) / float64(time.Millisecond),
		Consent: s.cfg.DecisionState, State: req.StateText,
	}
	if mp, ok := s.cfg.Backend.(DecisionMetaProvider); ok {
		m := mp.DecisionMeta(req.Model)
		f.ModelSHA256, f.TemplateHash, f.CalibrationProfile = m.ModelSHA256, m.TemplateHash, m.CalibrationProfile
	}
	if av, ok := c.Get(ckDecAns); ok {
		byName := map[string]contract.Answer{}
		for _, na := range av.([]contract.NamedAnswer) {
			byName[na.Name] = na.Answer
		}
		for _, q := range req.Questions {
			if a, ok := byName[q.Name]; ok {
				f.Answers = append(f.Answers, decisionAnswer(q, a))
			}
		}
	}
	if err := s.cfg.Decisions.WriteLine(audit.DecisionLine(audit.NewDecisionRecord(f))); err != nil {
		s.metrics.Inc(metrics.AuditWriteFailure)
		s.decisionErr.Do(func() {
			w := s.cfg.Stderr
			if w == nil {
				w = os.Stderr
			}
			fmt.Fprintf(w, "llmctl serve: decision log write failed: %v (further failures are only counted in llmctl_decide_audit_write_failures_total)\n", err)
		})
	}
}

// decisionAnswer summarises one answer: the index of the winning option (the best LISTED option;
// a bounded option is never the winner), the value of a noul/score answer and the served and raw
// confidence. The choice KEY is passed along for the builder, which drops it without consent.
func decisionAnswer(q contract.ParsedQuestion, a contract.Answer) audit.DecisionAnswer {
	da := audit.DecisionAnswer{Name: q.Name, Question: q.Instructions, Type: a.Type, ChoiceIndex: -1,
		Calibrated: a.Calibration != nil, Flags: a.Flags}
	if a.Type == contract.TypeNoul {
		v := a.Noul
		da.Value = &v
		return da
	}
	conf := a.Confidence
	da.Confidence = &conf
	if a.Calibration != nil {
		raw := a.ConfidenceRaw
		da.ConfidenceRaw = &raw
	}
	bounded := map[string]bool{}
	for _, u := range a.UpperBounds {
		bounded[u.Key] = true
	}
	best, bestV := -1, 0.0
	for i, o := range q.Options {
		if bounded[o.Key] {
			continue
		}
		for _, p := range a.Probabilities {
			if p.Key == o.Key && (best < 0 || p.Value > bestV) {
				best, bestV = i, p.Value
			}
		}
	}
	if a.Type == contract.TypeChoice {
		for i, o := range q.Options {
			if o.Key == a.Choice {
				best = i
			}
		}
	} else {
		v := a.Score
		da.Value = &v
	}
	if best >= 0 {
		da.ChoiceIndex, da.ChoiceKey = best, q.Options[best].Key
	}
	return da
}
