# Package D: timing diagnostics review

Analysis version 1 validates raw payloads before calculating eligible character
medians, nearest-rank p95, reference transitions and 64 active-time rhythm
buckets. Counts retain exclusion and clock provenance. The GUI receives a frozen
owned payload and owned analysis from the background worker for the requested
run; replacement, cancellation, clearing and shutdown release them.

Characters shows sample reliability, first-pass success, a median-of-run-medians
personal reference with a minimum of three other runs and five samples each,
and a context-matching character drill. Rhythm provides markers and a paginated
raw event inspector. Physical skill attribution is deliberately unavailable:
the current capture contains text events, so frozen routes are only possibilities.
This is the required missing-evidence state rather than fabricated modifier or
finger statistics. A guaranteed transition-specific corpus drill remains outside
the character drill's semantics and is identified in the tutor guide.

Review checked sample exclusion, empty/even quantiles, large-value overflow,
tail definition, missing/truncated payloads, selected-ID matching, pagination,
context bounds and clock provenance. Worker tests inspect retained raw reference
and empty analysis, then clear/requery to verify ownership replacement under the
testing allocator. Existing generation checks gate unsupported drill targets.

Visual verification compared native character, rhythm and provenance screens
with the D mockup at wide and small sizes. The native version uses separate tabs
for detailed rhythm/provenance to avoid crowding the character view. The slow
tail is explicitly p95, while the illustrative design used p90. Wrapping and
ASCII transition labels fix actual small-window/loaded-font issues found while
reviewing screenshots. Old-count-only rendering was checked separately. Native
evidence appears in the tutor guide; this was not a screenshot integration test.

Validation: exact Zig 0.17.0, native data/analysis contracts, desktop build and
existing offline GUI fixtures. Keyboard acceptance remains a manual follow-up.
