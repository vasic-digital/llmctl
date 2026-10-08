#!/usr/bin/env python3
"""onnx_server.py - llmctl INTERNAL encoder scoring runtime.

This is NOT a public API and contains NO typed-question logic. The Go
decision gateway (internal/server) owns the public API and the typed-question
contract (noul|choice|score) and calls this process over loopback, one
batch of (premise, hypothesis) pairs at a time. Python survives here ONLY
because onnxruntime is Python-only. See specs/009-jev-decision-models/
contracts/encoder-runtime.md (wire contract) and docs/scripts/onnx_server.md.

Hard rules (each is enforced in code and covered by tests/test_onnx_runtime.sh):
  * binds ONLY 127.0.0.1 (any other --host is refused);
  * every /v1/* request needs "Authorization: Bearer <key>"; the key is read
    from the file given by --api-key-file (mode 0600), never from argv or the
    environment, and compared in constant time;
  * GET /healthz is unauthenticated and returns exactly {"status":"ok"};
  * GET /readyz is unauthenticated, returns {"status":"ready"} (200) or
    {"status":"not_ready"} (503) and reflects a REAL 1-pair inference smoke
    run once at load;
  * only the PREMISE is ever truncated (token level, hypothesis + special
    tokens always survive) and `truncated` reports it per pair;
  * errors are JSON bodies with a 4xx/5xx status, never a dropped connection;
    NaN/Inf are never serialised;
  * there are NO test seams: unit tests inject stub onnxruntime/sentencepiece
    modules through PYTHONPATH (tests/fixtures/onnx_stubs/).

Wire API
  POST /v1/score   {"pairs":[{"premise":str,"hypothesis":str},...]}
    -> 200 {"labels":[...id2label order...], "label_source":str,
            "scores":[[p_label0,...],...], "truncated":[bool,...],
            "model":str, "max_tokens":int}
  GET  /healthz    -> 200 {"status":"ok"}
  GET  /readyz     -> 200 {"status":"ready"} | 503 {"status":"not_ready"}

Python >= 3.9, stdlib http.server; onnxruntime / numpy / sentencepiece /
tokenizers are imported lazily with a clear, actionable startup error.
Logging goes to STDOUT as single-line JSON and NEVER contains request text.
"""
import sys

sys.dont_write_bytecode = True  # never litter the repo tree with .pyc files

if sys.version_info < (3, 9):  # pragma: no cover - defensive, py2/3.8 hosts
    sys.stderr.write("onnx-server: Python >= 3.9 is required\n")
    sys.exit(2)

import argparse
import hmac
import json
import math
import os
import re
import socket
import stat
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOOPBACK = "127.0.0.1"
DEFAULT_MAX_TOKENS = 512
DEFAULT_MAX_PAIRS = 64
DEFAULT_MAX_BODY = 4 * 1024 * 1024
DEFAULT_CONCURRENCY = 4
DEFAULT_SOCKET_TIMEOUT = 30.0
BUSY_WAIT_SECONDS = 5.0
_GENERIC_LABEL = re.compile(r"^LABEL_\d+$")


def log_line(event, **fields):
    """Single-line JSON log record on stdout (service managers capture it)."""
    rec = {"component": "onnx-runtime", "event": event}
    rec.update(fields)
    sys.stdout.write(json.dumps(rec, default=str) + "\n")
    sys.stdout.flush()


def die(msg, rc=2):
    sys.stderr.write("onnx-server: %s\n" % msg)
    sys.exit(rc)


class RequestError(Exception):
    """A client/runtime error that maps to a JSON error response."""

    def __init__(self, status, code, message=""):
        Exception.__init__(self, message or code)
        self.status = status
        self.code = code
        self.message = message or code


# --- environment knobs -----------------------------------------------------------
def env_int(name, default, lo, hi):
    raw = os.environ.get(name, "")
    if raw == "":
        return default
    try:
        val = int(raw)
    except ValueError:
        die("%s must be an integer, got %r" % (name, raw))
    if not (lo <= val <= hi):
        die("%s must be within [%d, %d], got %d" % (name, lo, hi, val))
    return val


def profile_ctx(profile):
    """LLMCTL_CTX_<PROFILE> (profile upper-cased, non-alnum -> '_') or 0."""
    key = "LLMCTL_CTX_" + re.sub(r"[^A-Za-z0-9]", "_", profile).upper()
    raw = os.environ.get(key, "")
    if raw == "":
        return 0
    try:
        val = int(raw)
    except ValueError:
        die("%s must be an integer, got %r" % (key, raw))
    if val < 8:
        die("%s must be >= 8, got %d" % (key, val))
    return val


# --- API key ---------------------------------------------------------------------
def read_api_key(path):
    """Read the per-start internal key from a 0600 file. -> bytes."""
    try:
        st = os.stat(path)
    except OSError as exc:
        die("--api-key-file unreadable: %s" % exc.strerror, rc=1)
    if not stat.S_ISREG(st.st_mode):
        die("--api-key-file is not a regular file: %s" % path, rc=1)
    if st.st_mode & 0o077:
        die("--api-key-file must not be accessible by group/other (chmod 600 %s)" % path, rc=1)
    try:
        with open(path, "rb") as fh:
            data = fh.read(4097)
    except OSError as exc:
        die("--api-key-file unreadable: %s" % exc.strerror, rc=1)
    key = data.strip()
    if not key or len(data) > 4096:
        die("--api-key-file must hold a non-empty key of at most 4096 bytes", rc=1)
    return key


# --- label order -----------------------------------------------------------------
def load_labels(model_dir, model_path):
    """-> (labels_or_None, source).

    Config precedence (fixes defect N-21): the config.json that sits BESIDE the
    resolved model.onnx wins; the other location is consulted only when the
    first has no usable id2label. A config whose id2label is present but
    malformed (non-integer / non-contiguous ids) is a startup error - the
    runtime refuses to guess a label order. Generic LABEL_n names are kept
    but FLAGGED in `source` so the gateway can refuse to map them to
    entailment/contradiction semantics.
    """
    beside = os.path.dirname(model_path)
    cands = [os.path.join(beside, "config.json")]
    root = os.path.join(model_dir, "config.json")
    if root not in cands:
        cands.append(root)
    for cand in cands:
        if not os.path.isfile(cand):
            continue
        try:
            with open(cand, "r", encoding="utf-8") as fh:
                cfg = json.load(fh)
        except (OSError, ValueError) as exc:
            die("cannot parse %s: %s" % (cand, exc), rc=1)
        if not isinstance(cfg, dict):
            continue
        id2label = cfg.get("id2label")
        if id2label is None:
            continue
        if not isinstance(id2label, dict) or not id2label:
            die("%s: id2label must be a non-empty object" % cand, rc=1)
        pairs = []
        for k, v in id2label.items():
            try:
                pairs.append((int(k), str(v)))
            except (TypeError, ValueError):
                die("%s: id2label key %r is not an integer; refusing to guess "
                    "the label order" % (cand, k), rc=1)
        pairs.sort()
        if [p[0] for p in pairs] != list(range(len(pairs))):
            die("%s: id2label ids are not contiguous 0..n-1" % cand, rc=1)
        labels = [p[1] for p in pairs]
        rel = os.path.relpath(cand, model_dir)
        if all(_GENERIC_LABEL.match(lbl) for lbl in labels):
            return labels, "generic-config:%s (LABEL_n names carry no semantics)" % rel
        return labels, "config:%s" % rel
    return None, "none (no id2label found; labels are LABEL_n by logits count)"


# --- model -----------------------------------------------------------------------
def _find_first(model_dir, name):
    for cand in (os.path.join(model_dir, name), os.path.join(model_dir, "onnx", name)):
        if os.path.isfile(cand):
            return cand
    return None


class Scorer:
    """ONNX session + tokenizer. score() is safe to call from many threads."""

    def __init__(self, model_dir, tokenizer_name, max_tokens, model_name):
        self.max_tokens = max_tokens
        self.model_name = model_name
        model_path = _find_first(model_dir, "model.onnx")
        if model_path is None:
            die("no model.onnx found in %s (looked for model.onnx and onnx/model.onnx)"
                % model_dir, rc=1)
        try:
            import onnxruntime as ort
        except ImportError:
            die("onnxruntime is not installed. Run `llmctl build onnx` (creates the "
                "hash-locked private venv from lib/lock/requirements-onnx.lock); "
                "the scheduler launches this runtime with that venv's python.", rc=1)
        try:
            import numpy as np
        except ImportError:
            die("numpy is not installed. Run `llmctl build onnx`.", rc=1)
        self.np = np
        labels, self.label_source = load_labels(model_dir, model_path)
        self.labels = labels
        self._load_tokenizer(model_dir, tokenizer_name)
        opts = ort.SessionOptions()
        self.session = ort.InferenceSession(
            model_path, sess_options=opts, providers=["CPUExecutionProvider"])
        declared = [i.name for i in self.session.get_inputs()]
        known = ("input_ids", "attention_mask", "token_type_ids")
        unknown = [n for n in declared if n not in known]
        if unknown:
            die("model declares unsupported required input(s) %s; the runtime "
                "feeds only input_ids/attention_mask/token_type_ids" % unknown, rc=1)
        if "input_ids" not in declared:
            die("model does not declare an input_ids input (declared: %s)" % declared, rc=1)
        self.inputs = declared
        log_line("model_loaded", model=os.path.relpath(model_path, model_dir),
                 inputs=declared, tokenizer=tokenizer_name, max_tokens=max_tokens)

    # -- tokenizer ---------------------------------------------------------------
    def _load_tokenizer(self, model_dir, name):
        path = _find_first(model_dir, name)
        if path is None:
            die("tokenizer file not found: %s (or onnx/%s) in %s" % (name, name, model_dir), rc=1)
        if name.endswith(".json"):
            try:
                from tokenizers import Tokenizer
            except ImportError:
                die("tokenizer %s needs the `tokenizers` package. Run `llmctl build onnx`." % name, rc=1)
            tk = Tokenizer.from_file(path)
            tk.no_padding()
            # premise-only truncation done by the library at token level; set
            # ONCE here (the Tokenizer is shared across request threads).
            tk.enable_truncation(max_length=self.max_tokens, strategy="only_first")
            self.tok_kind, self.tok = "json", tk
            self.pad_id = 0
            for cand in ("[PAD]", "<pad>"):
                tid = tk.token_to_id(cand)
                if tid is not None:
                    self.pad_id = tid
                    break
            return
        try:
            import sentencepiece as spm
        except ImportError:
            die("sentencepiece is not installed. Run `llmctl build onnx`.", rc=1)
        sp = spm.SentencePieceProcessor()
        if not sp.Load(path):
            die("failed to load SentencePiece model: %s" % path, rc=1)
        self.tok_kind, self.tok = "spm", sp
        self.cls_id = sp.bos_id() if sp.bos_id() >= 0 else 1
        self.sep_id = sp.eos_id() if sp.eos_id() >= 0 else 2
        self.pad_id = sp.pad_id() if sp.pad_id() >= 0 else 0

    def encode(self, premise, hypothesis):
        """-> (ids, type_ids, truncated). Only the premise is shortened."""
        if self.tok_kind == "spm":
            tk = self.tok
            p_ids = list(tk.EncodeAsIds(premise))
            h_ids = list(tk.EncodeAsIds(hypothesis))
            budget = self.max_tokens - 3 - len(h_ids)  # [CLS] p [SEP] h [SEP]
            if budget < 1:
                raise RequestError(422, "hypothesis_too_long",
                                   "hypothesis alone needs %d tokens; max_tokens=%d "
                                   "leaves no room for the premise" % (len(h_ids), self.max_tokens))
            truncated = len(p_ids) > budget
            p_ids = p_ids[:budget]
            ids = [self.cls_id] + p_ids + [self.sep_id] + h_ids + [self.sep_id]
            types = [0] * (len(p_ids) + 2) + [1] * (len(h_ids) + 1)
            return ids, types, truncated
        tk = self.tok
        try:
            enc = tk.encode(premise, hypothesis)
        except Exception as exc:  # hypothesis alone exceeds max_tokens
            raise RequestError(422, "hypothesis_too_long",
                               "cannot fit the hypothesis in max_tokens=%d: %s"
                               % (self.max_tokens, type(exc).__name__))
        truncated = bool(getattr(enc, "overflowing", None))
        return list(enc.ids), list(enc.type_ids), truncated

    # -- inference ---------------------------------------------------------------
    def score(self, pairs):
        """pairs: [(premise, hypothesis)] -> (labels, scores, truncated)."""
        np = self.np
        encoded = [self.encode(p, h) for p, h in pairs]
        width = max(len(e[0]) for e in encoded)
        n = len(encoded)
        ids = np.full((n, width), self.pad_id, dtype=np.int64)
        mask = np.zeros((n, width), dtype=np.int64)
        types = np.zeros((n, width), dtype=np.int64)
        for i, (e_ids, e_types, _t) in enumerate(encoded):
            ids[i, :len(e_ids)] = e_ids
            mask[i, :len(e_ids)] = 1
            types[i, :len(e_types)] = e_types
        feeds = {}
        for name in self.inputs:
            feeds[name] = {"input_ids": ids, "attention_mask": mask,
                           "token_type_ids": types}[name]
        try:
            out = self.session.run(None, feeds)
            logits = np.asarray(out[0], dtype=np.float64)
        except Exception as exc:
            raise RequestError(500, "inference_failed", type(exc).__name__)
        if logits.ndim != 2 or logits.shape[0] != n:
            raise RequestError(500, "bad_logits_shape",
                               "model returned logits of shape %s for %d pairs"
                               % (list(logits.shape), n))
        n_labels = logits.shape[1]
        labels = self.labels
        if labels is None:
            labels = ["LABEL_%d" % i for i in range(n_labels)]
        elif len(labels) != n_labels:
            raise RequestError(500, "label_count_mismatch",
                               "model produced %d logits but id2label has %d labels"
                               % (n_labels, len(labels)))
        if not np.all(np.isfinite(logits)):
            raise RequestError(500, "non_finite_logits", "model produced non-finite logits")
        shifted = logits - logits.max(axis=1, keepdims=True)
        exps = np.exp(shifted)
        probs = exps / exps.sum(axis=1, keepdims=True)
        if not np.all(np.isfinite(probs)):
            raise RequestError(500, "non_finite_scores", "softmax produced non-finite scores")
        return list(labels), probs.tolist(), [e[2] for e in encoded]


# --- HTTP ------------------------------------------------------------------------
class State:
    def __init__(self, scorer, key, args, max_pairs, max_body, concurrency):
        self.scorer = scorer
        self.key = key
        self.model = args.model_name
        self.max_pairs = max_pairs
        self.max_body = max_body
        self.sem = threading.BoundedSemaphore(concurrency)
        self.ready = False


def parse_pairs(body):
    if not isinstance(body, dict):
        raise RequestError(400, "bad_request", "request body must be a JSON object")
    pairs = body.get("pairs")
    if not isinstance(pairs, list) or not pairs:
        raise RequestError(400, "bad_request", "pairs must be a non-empty array")
    out = []
    for i, item in enumerate(pairs):
        if not isinstance(item, dict):
            raise RequestError(400, "bad_request", "pairs[%d] must be an object" % i)
        p, h = item.get("premise"), item.get("hypothesis")
        if not isinstance(p, str) or not p:
            raise RequestError(400, "bad_request", "pairs[%d].premise must be a non-empty string" % i)
        if not isinstance(h, str) or not h:
            raise RequestError(400, "bad_request", "pairs[%d].hypothesis must be a non-empty string" % i)
        out.append((p, h))
    return out


def make_handler(st):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        timeout = DEFAULT_SOCKET_TIMEOUT  # per-connection socket timeout (D-09)
        server_version = "llmctl-encoder"
        sys_version = ""

        def log_message(self, *args):
            pass

        def _json(self, code, obj, close=False):
            body = json.dumps(obj, allow_nan=False).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            if code == 503:
                self.send_header("Retry-After", "1")
            if close or self.close_connection:
                self.send_header("Connection", "close")
                self.close_connection = True
            self.end_headers()
            self.wfile.write(body)

        def _err(self, status, code, message="", close=False):
            self._json(status, {"error": code, "message": message}, close=close)

        def send_error(self, code, message=None, explain=None):  # JSON, not HTML
            self.close_connection = True
            try:
                self._err(code, "http_error", message or "")
            except OSError:
                pass

        def _authorized(self):
            hdr = self.headers.get("Authorization") or ""
            if not hdr.startswith("Bearer "):
                # still burn a compare so timing does not reveal header shape
                hmac.compare_digest(st.key, st.key[::-1] + b"x")
                return False
            return hmac.compare_digest(hdr[7:].encode("utf-8", "replace"), st.key)

        def _body_length(self):
            """-> int length or raises RequestError (connection then closes)."""
            if self.headers.get("Transfer-Encoding"):
                raise RequestError(411, "length_required", "chunked bodies are not accepted")
            raw = self.headers.get("Content-Length")
            if raw is None:
                raise RequestError(411, "length_required", "Content-Length is required")
            try:
                length = int(raw)
            except ValueError:
                raise RequestError(400, "bad_request", "invalid Content-Length")
            if length <= 0:
                raise RequestError(400, "bad_request", "empty request body")
            if length > st.max_body:
                raise RequestError(413, "body_too_large",
                                   "body exceeds %d bytes" % st.max_body)
            return length

        def do_GET(self):
            path = self.path.split("?")[0]
            if path == "/healthz":
                self._json(200, {"status": "ok"})
            elif path == "/readyz":
                if st.ready:
                    self._json(200, {"status": "ready"})
                else:
                    self._json(503, {"status": "not_ready"})
            else:
                self._err(404, "not_found")

        def do_POST(self):
            path = self.path.split("?")[0]
            try:
                if path != "/v1/score":
                    self.close_connection = True  # body unread
                    raise RequestError(404, "not_found")
                if not self._authorized():
                    self.close_connection = True  # body unread
                    raise RequestError(401, "unauthorized", "missing or invalid bearer key")
                try:
                    length = self._body_length()
                except RequestError:
                    self.close_connection = True
                    raise
                try:
                    raw = self.rfile.read(length)
                except (socket.timeout, OSError):
                    self.close_connection = True
                    raise RequestError(408, "request_timeout", "body not received in time")
                if len(raw) != length:
                    self.close_connection = True
                    raise RequestError(400, "bad_request", "truncated request body")
                try:
                    body = json.loads(raw)
                except (ValueError, RecursionError):
                    raise RequestError(400, "bad_request", "request body is not valid JSON")
                pairs = parse_pairs(body)
                if len(pairs) > st.max_pairs:
                    raise RequestError(413, "too_many_pairs",
                                       "at most %d pairs per request" % st.max_pairs)
                if not st.ready:
                    raise RequestError(503, "not_ready", "model smoke test has not passed")
                if not st.sem.acquire(timeout=BUSY_WAIT_SECONDS):
                    raise RequestError(503, "busy", "all inference slots are busy")
                try:
                    labels, scores, trunc = st.scorer.score(pairs)
                finally:
                    st.sem.release()
                self._json(200, {"labels": labels,
                                 "label_source": st.scorer.label_source,
                                 "scores": scores, "truncated": trunc,
                                 "model": st.model,
                                 "max_tokens": st.scorer.max_tokens})
                log_line("score", pairs=len(pairs), truncated=sum(1 for t in trunc if t))
            except RequestError as exc:
                self._err(exc.status, exc.code, exc.message)
            except Exception as exc:  # never drop the connection (D-07, N-24)
                log_line("handler_error", error=type(exc).__name__)
                self.close_connection = True
                try:
                    self._err(500, "internal_error", type(exc).__name__)
                except OSError:
                    pass

        def _method_not_allowed(self):
            self.close_connection = True
            self._err(405, "method_not_allowed")

        do_PUT = do_DELETE = do_PATCH = do_OPTIONS = do_HEAD = _method_not_allowed

    return Handler


class LoopbackServer(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 64


def smoke(scorer):
    """Run one real pair through the model. -> (ok, detail)."""
    try:
        labels, scores, _t = scorer.score([("The cat sat on the mat.", "A cat is on a mat.")])
        ok = len(labels) >= 2 and len(scores[0]) == len(labels)
        return ok, "labels=%d" % len(labels)
    except RequestError as exc:
        return False, "%s: %s" % (exc.code, exc.message)
    except Exception as exc:
        return False, type(exc).__name__


def main(argv=None):
    ap = argparse.ArgumentParser(prog="onnx_server.py", allow_abbrev=False)
    ap.add_argument("--model-dir", default="")
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--host", default=LOOPBACK, help="must be 127.0.0.1")
    ap.add_argument("--api-key-file", default="",
                    help="file holding the per-start internal key (mode 0600)")
    ap.add_argument("--profile", default="")
    ap.add_argument("--tokenizer", default="spm.model",
                    help="tokenizer file in the model dir: spm.model or tokenizer.json")
    ap.add_argument("--max-tokens", type=int, default=0,
                    help="encoder sequence cap; default LLMCTL_CTX_<PROFILE> or %d"
                         % DEFAULT_MAX_TOKENS)
    args = ap.parse_args(argv)

    if args.host != LOOPBACK:
        die("--host must be %s (the encoder runtime is loopback-only), got %r"
            % (LOOPBACK, args.host))
    if not args.model_dir:
        die("--model-dir is required")
    if not os.path.isdir(args.model_dir):
        die("--model-dir is not a directory: %s" % args.model_dir, rc=1)
    if not args.port:
        die("--port is required")
    if not args.profile:
        die("--profile is required")
    if not args.api_key_file:
        die("--api-key-file is required (the key is never accepted on argv or via the environment)")
    if os.path.basename(args.tokenizer) != args.tokenizer or args.tokenizer in ("", ".", ".."):
        die("--tokenizer must be a bare file name inside the model dir, got %r" % args.tokenizer)
    max_tokens = args.max_tokens or profile_ctx(args.profile) or DEFAULT_MAX_TOKENS
    if max_tokens < 8:
        die("--max-tokens must be >= 8")
    max_pairs = env_int("LLMCTL_ONNX_MAX_PAIRS", DEFAULT_MAX_PAIRS, 1, 4096)
    max_body = env_int("LLMCTL_ONNX_MAX_BODY_BYTES", DEFAULT_MAX_BODY, 1024, 64 * 1024 * 1024)
    concurrency = env_int("LLMCTL_ONNX_MAX_CONCURRENCY", DEFAULT_CONCURRENCY, 1, 64)
    timeout = float(env_int("LLMCTL_ONNX_SOCKET_TIMEOUT", int(DEFAULT_SOCKET_TIMEOUT), 1, 600))

    key = read_api_key(args.api_key_file)
    args.model_name = "llmctl-%s" % args.profile
    scorer = Scorer(args.model_dir, args.tokenizer, max_tokens, args.model_name)

    st = State(scorer, key, args, max_pairs, max_body, concurrency)
    ok, detail = smoke(scorer)
    st.ready = ok
    log_line("smoke", ok=ok, detail=detail, label_source=scorer.label_source)

    handler = make_handler(st)
    handler.timeout = timeout
    server = LoopbackServer((LOOPBACK, args.port), handler)
    log_line("listening", host=LOOPBACK, port=args.port, profile=args.profile,
             ready=ok, max_tokens=max_tokens, max_pairs=max_pairs)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
