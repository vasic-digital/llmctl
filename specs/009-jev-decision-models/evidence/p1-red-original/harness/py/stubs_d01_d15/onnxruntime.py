"""Stand-in for the onnxruntime MODEL BACKEND only (never the code under test).
InferenceSession.run returns a fixed 2-logit row (a wrong-shaped head) so the
REAL lib/onnx_server.py OnnxModel.infer() error path executes."""
import numpy as np


class SessionOptions:
    pass


class InferenceSession:
    def __init__(self, path, sess_options=None, providers=None):
        self.path = path

    def run(self, names, feeds):
        return [np.array([[0.25, -0.25]], dtype=np.float32)]
