"""Loads one System One decision model and answers "pick one of these options" questions.

Shared by the local server (server.py) and the benchmark (bench/bench.py) so both
measure exactly what Bino runs.
"""
import contextlib
import os
import time

MODELS = {
    "decider-2b": ("Mapika/decider-2b-GGUF", "decider-2b-v11-Q4_K_M.gguf"),
    "decider-4b": ("Mapika/decider-4b-GGUF", "decider-4b-v2.1-Q4_K_M.gguf"),
    "laya": ("convaiinnovations/laya", None),
}
DEFAULT_MODEL = "decider-4b"


@contextlib.contextmanager
def _quiet_stderr():
    """llama.cpp prints hundreds of lines while loading; keep them out of the terminal."""
    fd = os.dup(2)
    devnull = os.open(os.devnull, os.O_WRONLY)
    try:
        os.dup2(devnull, 2)
        yield
    finally:
        os.dup2(fd, 2)
        os.close(devnull)
        os.close(fd)


class Engine:
    def __init__(self, model=DEFAULT_MODEL):
        if model not in MODELS:
            raise ValueError(f"unknown model {model!r}; choose from {sorted(MODELS)}")
        self.model = model
        started = time.time()
        if model == "laya":
            from laya import Router
            self._laya = Router()
        else:
            from decider.infer import Decider
            repo, gguf = MODELS[model]
            with _quiet_stderr():
                # Field descriptions are short, so a small context keeps memory low.
                self._decider = Decider(repo, gguf_file=gguf, gguf_options=dict(n_ctx=4096))
        self.load_seconds = time.time() - started

    def choose(self, state, question, options):
        """Returns {"choice": str, "confidence": float, "probs": {option: float}}."""
        if len(options) < 2:
            raise ValueError("need at least two options")
        if self.model == "laya":
            spec = {"q": {"type": "choice", "instructions": question, "criteria": {o: o for o in options}}}
            answer = self._laya.predict(state, spec)["answers"]["q"]
            probs = answer.get("probabilities") or answer.get("probs") or {}
            choice = answer["choice"]
            confidence = float(probs.get(choice, answer.get("confidence", 0.0)))
            return dict(choice=choice, confidence=confidence, probs={k: float(v) for k, v in probs.items()})
        result = self._decider.decide(state, [dict(question=question, options=list(options))])[0]
        probs = {k: float(v) for k, v in result["probs"].items()}
        choice = max(probs, key=probs.get)
        return dict(choice=choice, confidence=probs[choice], probs=probs)
