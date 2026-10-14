# Package C: progress evidence and review

Progress uses native DVUI plots with raw marks, optional exponential smoothing,
aligned axes, open gaps beyond 24 hours, visible UTC ranges and bounded filters.
Separate Trends and Activity tabs preserve the compact rundown. The matrix links
saved run IDs and character selection back to the rundown. It supports counts,
exposure and clean timing medians; empty/old/truncated samples remain explicit.

The background query uses the indexed exact-cohort run stream. The UI receives
at most 60 compact summaries, 28 daily totals and the existing ten-record page.
Raw event payloads are decoded individually on the background worker to enrich
those summaries. No raw event loading or median calculation runs during drawing.
All matching scored completed runs contribute to daily totals, including runs
outside the plotted window. UTC is the deliberate day-boundary policy.

Review found stack pressure from storing enriched arrays in the returned query.
The summary now has explicit heap ownership; poll replacement, cancellation and
shutdown free it. The GUI's filtered copy uses its frame arena. Native contract
tests verify bounded order, day totals beyond the point cap, eligibility,
streak boundaries, excluded intervals and even-sample median calculation. The
worker contract verifies selected-run retrieval and runs with allocator checks.

Visual review compared native wide/small Trends and Activity with the package C
mockup. Native empty and singleton scenes were also inspected. Small windows
scroll rather than squeezing graphs into the rundown. Compact cells use explicit
padding/font sizes after screenshot review exposed clipped date labels. Saved
screenshots appear in the tutor guide. These are visual verification artifacts,
not screenshot integration tests.

Validation uses exact Zig 0.17.0, native data contracts, desktop build and the
existing offline GUI fixtures. Hardware acceptance remains for the user's return.
Curriculum annotations will be explicit once package E introduces curriculum
cohorts; the current view already separates assistance and exercise modes.
