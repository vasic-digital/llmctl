"""Unit tests for the pure parts of the client-by-call matrix harness (tests/matrix)."""
import base64
import unittest

from tests.matrix import cases as C
from tests.matrix import run as M

INV = ["EP-001", "EP-002"]


def cell(cid, client, result="pass", cls=None, vantage="host"):
    return {"case_id": cid, "client": client, "vantage": vantage, "result": result, "reason_class": cls, "reason": "r"}


class CompletenessTests(unittest.TestCase):
    def full(self):
        return [cell(c, k) for c in INV for k in ("curl", "node-fetch")]

    def check(self, cells, inv=INV, handlers=None, allow=False):
        return M.check_completeness(inv, handlers if handlers is not None else INV, ["curl", "node-fetch"], ["host"], cells, allow)

    # basis: specs/009-jev-decision-models/contracts/evidence-schema.md:33 (rule 3: one record per case x client x vantage; a complete matrix passes the completeness check)
    # oracle: SPECIFIED
    def test_complete_matrix_has_no_problems(self):
        self.assertEqual(self.check(self.full()), [])

    # basis: specs/009-jev-decision-models/contracts/evidence-schema.md:33 (a missing cell is a failure, not a skip); the message prefix is the harness's wording
    # oracle: SPECIFIED
    def test_missing_cell_is_a_problem_not_a_skip(self):
        p = self.check(self.full()[:-1])
        self.assertTrue(any(x.startswith("MISSING cell EP-002 x node-fetch") for x in p), p)

    # basis: pins the harness's own inventory-versus-handler cross-check on a constructed EP-999 row; specs/009-jev-decision-models/contracts/evidence-schema.md:33 names the inventory but not this check
    # oracle: CHARACTERIZATION
    def test_inventory_row_without_handler(self):
        p = self.check(self.full(), inv=INV + ["EP-999"])
        self.assertTrue(any("EP-999" in x and "no handler" in x for x in p), p)

    # basis: pins the harness's own reverse cross-check; no spec text
    # oracle: CHARACTERIZATION
    def test_handler_without_inventory_row_detects_removed_row(self):
        p = self.check(self.full(), inv=["EP-001"], handlers=INV)
        self.assertTrue(any("EP-002" in x and "not in the inventory" in x for x in p), p)

    # basis: pins the harness's own duplicate and unexpected cell detection on constructed cells; no spec text
    # oracle: CHARACTERIZATION
    def test_duplicate_and_unexpected_cells(self):
        p = self.check(self.full() + [cell("EP-001", "curl"), cell("EP-777", "curl")])
        self.assertTrue(any("duplicate" in x for x in p) and any("unexpected" in x for x in p), p)

    # basis: the declared reason classes (browser-non-get) are defined in tests/matrix/run.py, the code under test; specs/009-jev-decision-models/contracts/evidence-schema.md:25 only requires a reason
    # oracle: CHARACTERIZATION
    def test_not_exercised_needs_a_declared_class(self):
        cells = self.full()
        cells[0] = cell("EP-001", "curl", "not-exercised", "because-i-said-so")
        self.assertTrue(any("undeclared class" in x for x in self.check(cells)))
        cells[0] = cell("EP-001", "curl", "not-exercised", "browser-non-get")
        self.assertEqual(self.check(cells), [])

    # basis: pins the harness's own env-gap rule (NE_CLASS_ENV counts as failure unless allowed); no spec text
    # oracle: CHARACTERIZATION
    def test_env_gap_is_a_failure_unless_allowed(self):
        cells = self.full()
        cells[0] = cell("EP-001", "curl", "not-exercised", M.NE_CLASS_ENV)
        self.assertTrue(any("env-gap" in x for x in self.check(cells)))
        self.assertEqual(self.check(cells, allow=True), [])


class ParseTests(unittest.TestCase):
    # basis: pins the line protocol (STATUS/HEADER/BODY_B64/TRUST) the in-repo client adapters and parse_lines define between them; no external spec; the base64 of {} is encoded in the test
    # oracle: CHARACTERIZATION
    def test_line_protocol(self):
        out = "STATUS 401\nHEADER www-authenticate: Bearer realm=\"llmctl\"\nBODY_B64 %s\nTRUST env ok\n" % base64.b64encode(b"{}").decode()
        r = M.parse_lines(out)
        self.assertEqual((r.status, r.body, r.trust), (401, b"{}", ["env ok"]))
        self.assertEqual(r.headers["www-authenticate"], 'Bearer realm="llmctl"')

    # basis: pins parse_lines on an ERROR-only adapter output as designed; no spec text
    # oracle: CHARACTERIZATION
    def test_error_only(self):
        r = M.parse_lines("ERROR boom\n")
        self.assertIsNone(r.status)
        self.assertEqual(r.error, "boom")


class ValidatorTests(unittest.TestCase):
    REQ = {"questions": {"a": {"type": "noul"}, "b": {"type": "choice", "criteria": {"x": None, "y": None}}}}
    GOOD = {"model": "m", "usage": {"input_tokens": 1, "output_tokens": 2},
            "answers": {"a": {"type": "noul", "noul": 0.5},
                        "b": {"type": "choice", "choice": "x", "probabilities": {"x": 0.7, "y": 0.3}, "confidence": 0.4}}}

    # basis: specs/009-jev-decision-models/contracts/openapi.yaml:262-278 (SystemOneResponse model, answers, usage) and :286-316 (Noul and Choice answers)
    # oracle: SPECIFIED
    def test_good_body(self):
        self.assertEqual(C.validate_systemone(self.GOOD, self.REQ), [])

    # basis: specs/009-jev-decision-models/contracts/openapi.yaml:296-316 (ChoiceAnswer probabilities sum to 1 within 1e-6; line 306 is the sum rule); 0.8 total is hand-made
    # oracle: SPECIFIED
    def test_probabilities_must_sum_to_one(self):
        bad = {**self.GOOD, "answers": {**self.GOOD["answers"], "b": {**self.GOOD["answers"]["b"], "probabilities": {"x": 0.7, "y": 0.1}}}}
        self.assertTrue(C.validate_systemone(bad, self.REQ))

    # basis: specs/009-jev-decision-models/contracts/openapi.yaml:262-278 (SystemOneResponse additionalProperties false; answers keyed by the request question keys); the message text 'answer keys' is the validator's wording
    # oracle: SPECIFIED
    def test_missing_answer_and_extra_key(self):
        bad = {**self.GOOD, "answers": {"a": self.GOOD["answers"]["a"]}}
        self.assertTrue(any("answer keys" in x for x in C.validate_systemone(bad, self.REQ)))
        self.assertTrue(C.validate_systemone({**self.GOOD, "extra": 1}, self.REQ))

    # basis: pins check_step's status and error_type comparison against constructed 401 steps; 401 with WWW-Authenticate Bearer realm llmctl per specs/009-jev-decision-models/contracts/openapi.yaml:21,:469-471
    # oracle: CHARACTERIZATION
    def test_check_step_rejects_wrong_status_and_error_type(self):
        st = C.err(401, "unauthorized", auth="none", body={}, check=["www-authenticate"])
        r = M.parse_lines("STATUS 401\nHEADER www-authenticate: Bearer realm=\"llmctl\"\nBODY_B64 %s\n" %
                          base64.b64encode(b'{"message":"x","error_type":"unauthorized"}').decode())
        self.assertEqual(M.check_step(st, r), [])
        r.status = 403
        self.assertTrue(M.check_step(st, r))
        r.status = 401
        r.body = b'{"message":"x","error_type":"invalid_request"}'
        self.assertTrue(any("error_type" in x for x in M.check_step(st, r)))

    # basis: specs/009-jev-decision-models/contracts/evidence-schema.md:33 and specs/009-jev-decision-models/contracts/endpoint-inventory.tsv (the inventory is the contract file; the case table is the harness's own handler set, so the check cross-references two repo files)
    # oracle: SPECIFIED
    def test_every_case_in_the_default_inventory_has_a_handler(self):
        ids = [r["case_id"] for r in M.load_inventory(M.DEFAULT_INVENTORY)]
        self.assertEqual(sorted(ids), sorted(C.cases(C.Params())))


if __name__ == "__main__":
    unittest.main()
