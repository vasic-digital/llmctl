"""The matrix validators accept exactly the additive FR-080 fields of a calibrating gateway
(answer: confidence_raw + calibration{method,n,profile_id}; /v1/models: template_hash, calibration)
and still reject malformed or half-present ones."""
import copy
import unittest

from tests.matrix import cases as C

CAL = {"method": "temperature", "n": 240, "profile_id": "decide-tiny"}
REQ = {"questions": {"b": {"type": "choice", "criteria": {"x": None, "y": None}}}}
BODY = {"model": "m", "usage": {"input_tokens": 1, "output_tokens": 2},
        "answers": {"b": {"type": "choice", "choice": "x", "probabilities": {"x": 0.7, "y": 0.3}, "confidence": 0.8,
                          "confidence_raw": 0.4, "calibration": CAL}}}
SBODY = {"model": "m", "usage": {"input_tokens": 1, "output_tokens": 2},
         "answers": {"s": {"type": "score", "score": 1.0, "legend": {"0": "a", "1": "b"},
                           "probabilities": {"0": 0.5, "1": 0.5}, "confidence": 0.6, "confidence_raw": 0.0,
                           "calibration": CAL}}}
SREQ = {"questions": {"s": {"type": "score", "criteria": ["a", "b"]}}}


def mut(body, q, **kw):
    b = copy.deepcopy(body)
    for k, v in kw.items():
        if v is None:
            b["answers"][q].pop(k, None)
        else:
            b["answers"][q][k] = v
    return b


class AnswerFields(unittest.TestCase):
    def test_calibrated_choice_and_score_are_valid(self):
        self.assertEqual(C.validate_systemone(BODY, REQ), [])
        self.assertEqual(C.validate_systemone(SBODY, SREQ), [])

    def test_half_present_or_malformed_calibration_is_rejected(self):
        for name, bad in {
            "raw without calibration": mut(BODY, "b", calibration=None),
            "calibration without raw": mut(BODY, "b", confidence_raw=None),
            "raw out of range": mut(BODY, "b", confidence_raw=1.5),
            "calibration not an object": mut(BODY, "b", calibration="temperature"),
            "calibration missing n": mut(BODY, "b", calibration={"method": "temperature", "profile_id": "p"}),
            "calibration extra key": mut(BODY, "b", calibration={**CAL, "x": 1}),
            "unknown method": mut(BODY, "b", calibration={**CAL, "method": "magic"}),
            "stray answer key": mut(BODY, "b", surprise=1),
        }.items():
            self.assertTrue(C.validate_systemone(bad, REQ), name)


class ModelFields(unittest.TestCase):
    SDK = [{"name": "decide-tiny", "description": "d", "release_date": "2026-01-01"}]

    def env(self, **kw):
        m = {"id": "decide-tiny", "aliases": [], "protocol": "letter-logit", "status": "ready",
             "limits": {"max_options": 26, "score_levels": [2, 7]}}
        m.update(kw)
        return {"object": "list", "data": [m], "models": self.SDK}

    def test_template_hash_and_calibration_are_accepted(self):
        h = "ab" * 32
        self.assertEqual(C.validate_models(self.env()), [])
        self.assertEqual(C.validate_models(self.env(template_hash=h, calibration={"applied": True, **CAL})), [])
        self.assertEqual(C.validate_models(self.env(template_hash=h, calibration={"applied": False, "reason": "mismatch"})), [])

    def test_malformed_additive_fields_are_rejected(self):
        for name, kw in {
            "short hash": {"template_hash": "abc"},
            "uppercase hash": {"template_hash": "AB" * 32},
            "calibration without applied": {"calibration": {"reason": "mismatch"}},
            "applied non-bool": {"calibration": {"applied": "yes"}},
            "unknown reason": {"calibration": {"applied": False, "reason": "because"}},
            "applied false with method": {"calibration": {"applied": False, "method": "platt"}},
            "stray key": {"surprise": 1},
        }.items():
            self.assertTrue(C.validate_models(self.env(**kw)), name)


if __name__ == "__main__":
    unittest.main()
