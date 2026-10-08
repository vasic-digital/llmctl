"""Shared inputs for the D-01 RED/GREEN reproduction (deterministic, no randomness)."""
HYP = ("Option A is the correct action for this decision: restart the failed service now.")
def long_state(n_sentences=20):
    base = ("Observation %d: the monitoring agent recorded a transient latency spike on node %d "
            "while the queue depth stayed within its configured limits and no operator action was pending.")
    return " ".join(base % (i, i % 7) for i in range(n_sentences))
