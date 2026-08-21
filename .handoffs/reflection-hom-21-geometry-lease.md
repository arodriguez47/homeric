# Reflection: HOM-21 geometry lease

Document identity and layout generation were both correct but insufficient.
IME geometry follows an attachment, not merely content. The strongest version
of the fix also had to guard lease acquisition: a session-wide getter would
have allowed a stale row to borrow the new row's valid lease during a transient
retarget. Restricting retrieval to the exact `(blockId, owner)` pair made the
capability revocable at both acquisition and use.

The remaining HOM-21 work is evidence-heavy rather than locally hidden: real
platform composition, candidate, focus-loss, and connection-loss runs are still
required. Widget and macOS-host integration results remain supporting evidence
only.
