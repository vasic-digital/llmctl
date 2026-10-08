"""Shared deterministic word->id map for the stub tokenizers (test fixture only)."""
import zlib

CLS, SEP, NOT = 1, 2, 7


def word_id(w):
    if w.lower() == "not":
        return NOT
    return 100 + (zlib.crc32(w.encode("utf-8")) % 1000)


def words(text):
    return [word_id(w) for w in text.split()]
