"""The product build's own state, ported from `scripts/state-*.sh` (#106).

Distinct from a *run*'s state, which lives in `persistence/`. A run is one issue moving through
the seven states; a product build is the longer thing that opens those issues, and the two have
different lifetimes, different readers and different shapes.
"""

from ai_harness.product.shards import PathError, Shard, shard_for
from ai_harness.product.state import ProductState, StateError

__all__ = ["PathError", "ProductState", "Shard", "StateError", "shard_for"]
