"""The scout — a separate service, not a state (Q12).

It shares ``kernel/``, ``llm/`` and ``providers/`` and has its own lifecycle and its own
accept-rate economics. What it must never do is start a run: it **files issues**, and a human
relabels the ones worth building. That separation is enforced by an import contract rather than
by convention, because the whole value of the scout depends on its output being cheap to reject.
"""
