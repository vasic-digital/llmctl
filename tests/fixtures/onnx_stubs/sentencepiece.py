"""Stand-in for the SentencePiece tokenizer backend only."""
import os

from _words import words


class SentencePieceProcessor:
    def Load(self, path):
        return os.path.isfile(path) and os.path.getsize(path) > 0

    def EncodeAsIds(self, text):
        return words(text)

    def bos_id(self):
        return 1

    def eos_id(self):
        return 2

    def pad_id(self):
        return -1
