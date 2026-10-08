"""Stand-in for the SentencePiece tokenizer backend only."""


class SentencePieceProcessor:
    def Load(self, path):
        return True

    def EncodeAsIds(self, text):
        return [3 + (ord(c) % 50) for c in text.split()] or [3]

    def bos_id(self):
        return 1

    def eos_id(self):
        return 2
