"""Stand-in for the `tokenizers` package (JSON tokenizer path) - word level,
BERT-style pair template [CLS] p [SEP] h [SEP], only_first truncation."""
from _words import CLS, SEP, words


class _Enc:
    def __init__(self, ids, type_ids, overflowing):
        self.ids, self.type_ids, self.overflowing = ids, type_ids, overflowing


class Tokenizer:
    @classmethod
    def from_file(cls, path):
        t = cls()
        t.max_length = None
        return t

    def no_padding(self):
        pass

    def enable_truncation(self, max_length, strategy="longest_first"):
        assert strategy == "only_first", strategy
        self.max_length = max_length

    def token_to_id(self, tok):
        return {"[PAD]": 0, "[CLS]": CLS, "[SEP]": SEP}.get(tok)

    def encode(self, p, h):
        pi, hi = words(p), words(h)
        budget = (self.max_length or 10 ** 9) - 3 - len(hi)
        if budget < 1:
            raise Exception("Truncation error: Second sequence not provided / too long")
        over = [pi[budget:]] if len(pi) > budget else []
        pi = pi[:budget]
        ids = [CLS] + pi + [SEP] + hi + [SEP]
        return _Enc(ids, [0] * (len(pi) + 2) + [1] * (len(hi) + 1), over)
