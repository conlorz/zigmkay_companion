# Package B: compact rundown review

The native view separates speed, attempt accuracy and occurrence success, adds
an evidence-gated recommendation, exposure heatmap mode, sortable linked
character rows and selected confusion drills. Advanced route/context/clear
controls stay behind More details.

Visual verification used the existing offline native renderer at wide and small
window sizes, compared directly with the package B design. Wide windows place
the keyboard beside character evidence; small windows stack them. Real captures
are in the tutor guide. This is a manual visual comparison, not a screenshot
integration assertion. Native DVUI typography and controls differ from the design
study while preserving its information hierarchy. Keyboard hardware remains for
manual acceptance.

Review corrected recent-baseline membership: a run present in all history may
be absent from the newest ten. Explicit recent IDs prevent subtracting an older
reviewed run from that baseline or suppressing a newly completed run. Existing
cohort equality remains mandatory. Weighted speed excludes the displayed run
only when its ID is actually present. Empty/zero-duration histories display no
baseline rather than manufacturing a delta.

Occurrence success and retry/substitution counts remain separate. Confusion
drills require repeated evidence and pass the generator's existing corpus
coverage checks. Exposure colors retain counts and limited-evidence labels.
No inference of actual physical fingering is added.

Validation: exact Zig 0.17.0, native data contracts, desktop build, existing
offline tutor/rundown/launch/source/companion fixtures, and whitespace checks.
The recent-history contract now verifies baseline membership across older pages.
