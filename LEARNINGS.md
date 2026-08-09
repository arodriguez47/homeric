# LEARNINGS — Homeric

Format matches Nexus: `## <role> — <date> — <topic>`, with **What changed** /
**Why it mattered** / **Rule going forward**.

Seeded from the Nexus session that produced the decision to build this package
(2026-08-08). See `AGENTS.md` for the cross-repo clause governing which lessons
land in both repos.

---

## architect — 2026-08-08 — A workaround repeated three times is a missing primitive, and the third one is a feature you couldn't build

**What changed:** Nexus's journal runs on AppFlowy Editor, which maps
`Position.offset` straight onto `TextPosition.offset` in a block's one laid-out
`RenderParagraph`. That forces rendered length to equal document length, and four
features paid the tax in the same coin:

| Feature | Accommodation |
|---|---|
| Bold/italic delimiters | Rendered at `fontSize: 0` — present in the text, zero advance width |
| Inline `++aside++` comments | Replace exactly one character with exactly one `WidgetSpan` carrying that character plus its chips |
| Multi-character anchors | Cannot preserve the count → degrade to an appended block-end tail |
| Footnote markers | `Positioned` overlay, because a marker sits *between* two characters and has no character to consume |

**Why it mattered:** The first two are workarounds. The last two are not — they are
capabilities the constraint made unbuildable, wearing a fallback. Individually each
looked like an acceptable local trade. Counted together they were the argument for
this package.

**Rule going forward:** This is the class of problem Homeric exists to remove. A
decoration API that cannot express "this range renders as *n* characters, where *n*
may be zero, and may be a widget" will regrow all four accommodations. Judge the
`DecorationSet` design against that table, not against how clean its types are.

## architect — 2026-08-08 — An architecture estimate that drives a "no" is a claim about the code, and gets verified like one

**What changed:** The decision doc that initially recommended *against* building
this asserted the offset-mapping surface was wide: *"selection painting, caret rect
computation, hit testing, IME composing ranges, and every delta operation that
derives an offset from a tap."* Measured against the actual package: **5
`TextPosition(` construction sites, all in one file.** Six text block types share
one forwarder that never touches offsets; five non-text types are 0/1 selections
where a map is a no-op. Eight methods, each a one-line substitution.

**Why it mattered:** Off by an order of magnitude, in the expensive direction, and
it was the concrete-sounding half of an otherwise opportunity-cost argument. An
unverified scope claim inside a decision document is indistinguishable from a
verified one once written.

**Rule going forward:** Homeric's own `docs/ARCHITECTURE_DECISION.md` and
`docs/PERF_BUDGET.md` are full of numbers that will get quoted back as settled.
Any figure load-bearing enough to decide against work carries the command that
produced it.

## architect — 2026-08-08 — Classify every offset consumer as document-space or view-space before introducing a map

**What changed:** Surveying where a document↔view map would have to be threaded
turned up three distinct categories:

- **Never map the platform IME path.** AppFlowy's `_getCurrentTextEditingValue`
  builds `TextEditingValue` from document plain text and document offsets. It talks
  to the platform, not the render tree. Mapping it corrupts composing ranges on
  every platform.
- **Character movement never enters the render tree.** Arrow left/right go through
  `Delta.prevRunePosition`/`nextRunePosition` over `CharacterBoundary` on document
  text. A render-side map does not reach it; hidden ranges need a separate atomic
  hook.
- **Word and vertical movement do round-trip the render tree** and inherit the map
  for free.

**Why it mattered:** Two of these fail silently. Mapping the IME path yields
platform-specific composing bugs no widget test sees. Assuming the map covers
character movement yields arrow keys that still stall on hidden ranges, which reads
as a broken map rather than a missing hook.

**Rule going forward:** Homeric owns both sides, so the split must be explicit in
the type system, not in convention: document positions and view positions should
not be the same type. If a single `int` offset can be passed to both the IME layer
and the paragraph builder, this lesson will be relearned on a device.

## architect — 2026-08-08 — A 32-week roadmap with no consumer is a five-minute project

**What changed:** This repo's first life: created 2026-06-11 01:44:52Z, last pushed
01:50:11Z. Three commits, the last two 37 seconds apart. A mechanical rename of
`super_editor 0.3.0-dev.51` into four Melos packages, plus a 177-line architecture
decision, a 32-week roadmap, and a perf budget with a 5% CI gate. Of the three
planned additions — viewport virtualization, `StepMap`, `DecorationSet` — **zero
lines were written.**

**Why it mattered:** It did not stall in Phase 2 or hit a wall in Phase 3. It
stopped at the end of the scaffolding commit, before Phase 1 Week 3. The design was
the deliverable and the implementation was never begun. The plan was not the
problem — the plan was good, and most of it survived into this one.

**Rule going forward:** Every phase after the first lands in Nexus. Phase 1
(document model, `StepMap`, `DecorationSet`) is the sole exception and is scoped in
weeks. If a phase's definition of done can be met without a consumer running the
code, the phase is scoped wrong. HOM-4's checkpoint states this as the project's
single most important signal.
