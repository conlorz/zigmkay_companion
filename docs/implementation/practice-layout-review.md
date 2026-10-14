# Native tutor layout review

The first implementation retained the features in the six UI studies but lost
their hierarchy: centered text, long control rows, flat backgrounds and oversized
explanations made it harder to scan. This review captured the actual macOS app,
compared every new panel with its study, and changed the native layouts.

Shared page insets, left-aligned headings, rounded cards, larger primary values,
shorter supporting text and one clear next action now carry the hierarchy.
Progress puts its two plots beside the character matrix in wide windows. Lessons
put the learning path beside the current lesson and exercise options. Smaller
windows stack those cards instead of squeezing their text. Review rules stay
behind an explicit toggle. More contains the secondary tutor tools.

## Mockup, before and after

These are native offline renders with synthetic exercise/history fixtures, not
measurements from a keyboard or claims about the learner's progress.

| Panel | Original study | Before cleanup | Current native view |
| --- | --- | --- | --- |
| Practice data | [A](../design/typing-practice/01-data.png) | [Before](../screenshots/tutor-layout-review/before-data.png) | [Wide](../screenshots/typing-practice/data-wide.png), [small](../screenshots/typing-practice/data-small.png) |
| Rundown | [B](../design/typing-practice/02-rundown.png) | [Before](../screenshots/tutor-layout-review/before-rundown.png) | [Wide](../screenshots/typing-practice/rundown-compact-wide.png), [small](../screenshots/typing-practice/rundown-compact-small.png) |
| Progress | [C](../design/typing-practice/03-progress.png) | [Before](../screenshots/tutor-layout-review/before-progress.png) | [Trends](../screenshots/typing-practice/progress-wide.png), [activity](../screenshots/typing-practice/activity-wide.png), [small](../screenshots/typing-practice/progress-small.png) |
| Timing details | [D](../design/typing-practice/04-diagnostics.png) | [Before](../screenshots/tutor-layout-review/before-diagnostics.png) | [Characters](../screenshots/typing-practice/diagnostics-wide.png), [rhythm](../screenshots/typing-practice/rhythm-wide.png), [provenance](../screenshots/typing-practice/skills-wide.png) |
| Guided lessons | [E](../design/typing-practice/05-curriculum.png) | [Before](../screenshots/tutor-layout-review/before-curriculum.png) | [Wide](../screenshots/typing-practice/curriculum-wide.png), [small](../screenshots/typing-practice/curriculum-small.png) |
| Help and review | [F](../design/typing-practice/06-help.png) | [Before settings](../screenshots/tutor-layout-review/before-hints.png) | [Settings](../screenshots/tutor-layout-review/hint-settings.png), [review](../screenshots/typing-practice/review-wide.png), [keyboard hint](../screenshots/typing-practice/help-wide.png) |

The mockup values and keyboard geometry remain illustrative. Native panels use
the actual saved layout and available evidence. No progress curve, mastery state
or physical route is invented to reproduce an example picture. F also follows
manual feedback: its hint paragraph is removed and the keyboard stays fixed.

## Clipping and interaction audit

- Replaced an overcrowded toolbar with Progress, Lessons, Review and More.
- Removed ellipsized learning-path headings; shortened navigation labels.
- Kept New exercise and supported weak-spot drills visible near the rundown top.
- Wrapped descriptions, long history folders, errors and selected-event context.
  The editable filename field retains ordinary horizontal scrolling.
- Used compact SPC/RET/TAB labels and smaller heatmap typography so key labels
  and sample counts remain readable. Character rows retain full evidence.
- Sized matrix columns to the available card width. Day headers share an explicit
  UTC date range; character cells show success, exposure or clean timing.
- Split timing metrics into three cards and transition rows into primary values
  and sample notes. Raw event rows use left-aligned text and taller hit areas.
- Verified the lower parts of small panels with actual mouse-wheel scrolling:
  transfer actions, matrix notes, lesson actions, raw-event inspector, hint Apply
  and expanded review rules remain reachable and readable.
- Replaced unsupported arrow glyphs in the new paragraph/label paths. Native
  logging exposed duplicate widget IDs in repeated rows and a full progress bar;
  stable row identities and separate surface identities resolve those errors.
- At extreme menu zoom, a minimum readable content width allows horizontal
  scrolling instead of negative child widths or inaccessible actions.
- Saved history uses the page's main scroll rather than a tiny nested list.
  More details grows the scroll extent for wrapped metadata; clear-history
  confirmation has a separate card with spaced actions.
- Progress errors sit below the stacked matrix. Timing notices move below
  truncation notes and all possible-route rows instead of overlapping them.

Rounded surfaces and plot ranges change presentation only. Scoring, cue capture,
exact history cohorts, curriculum policy, import/export semantics and keyboard
hint placement retain their existing contracts. The accuracy plot focuses on
its measured range with visible axis limits. Raw points remain separate from
optional smoothing. Fading a hint never changes the keyboard rectangle.

The initial data screenshot reused an existing fixture database and showed a
preview failure. Layout captures now use a fresh owned cache directory per run;
production data paths and migrations are unchanged.

## Code review

The review checked dynamic scroll extents, repeated widget identities, narrow
width calculations, early-return cleanup and retained action contracts. DVUI
children with explicit rectangles do not automatically enlarge their parent;
expanded rundown, recall and timing content now declares its required height.
Recall filtering is applied before computing row positions, so changing a
checkbox cannot overlap rows for a frame. Error, truncation and route notices
have separate footer space. Native logs report no duplicate-widget errors.

The shared row buttons retain normal DVUI event processing and focus drawing.
Database transfers, drill preflight, lesson progression and recall qualification
still use their existing controllers. The review did not find outstanding
blocking issues in these changes; real keyboard and other-platform GUI checks
remain the manual acceptance items described below.

## Scrolled verification

| Panel | Native capture after scrolling |
| --- | --- |
| Data controls | [Import/export](../screenshots/tutor-layout-review/data-footer.png) |
| Progress | [Character matrix](../screenshots/tutor-layout-review/progress-footer.png) |
| Lessons | [Start and restore](../screenshots/tutor-layout-review/lesson-footer.png) |
| Timing | [Transitions](../screenshots/tutor-layout-review/diagnostics-footer.png), [raw event details](../screenshots/tutor-layout-review/events-footer.png) |
| Hint settings | [Apply](../screenshots/tutor-layout-review/hint-settings-footer.png) |
| Recall rules | [Expanded rules](../screenshots/tutor-layout-review/review-rules.png) |
| Secondary rundown | [Saved history](../screenshots/typing-practice/history.png), [more details](../screenshots/tutor-layout-review/rundown-details.png), [clear confirmation](../screenshots/tutor-layout-review/clear-history.png) |

The [More menu](../screenshots/tutor-layout-review/more-menu.png) was opened with
native mouse events after the resize settled. Secondary tools remain accessible
without adding another toolbar row. Compare [hint off](../screenshots/tutor-layout-review/hint-off.png)
with [hint on](../screenshots/typing-practice/help-wide.png): the key rectangles
stay fixed.

## Reproduce the visual review

With the prepared desktop dependencies and exactly Zig 0.17.0:

```sh
mise run editor -- -- --native-layout-data-frames 72
mise run editor -- -- --native-layout-progress-frames 96
mise run editor -- -- --native-layout-diagnostics-frames 90
mise run editor -- -- --native-layout-curriculum-frames 108
mise run editor -- -- --native-layout-help-frames 126
mise run editor -- -- --native-layout-rundown-frames 78
```

These explicit offline gallery modes have no hardware monitoring. Each scene
gets six frames to settle layout after a resize. Native SDL framebuffer captures
are saved in `.zig-cache/typing-practice-gallery/`: frame `6n-3` shows the top of
scene `n`; frame `6n` shows it after real scrolling where applicable. Convert
selected BMPs to PNG for inspection. There are no pixel assertions or new
screenshot integration tests.

Validation includes the desktop build and existing offline launch, practice,
rundown, source-refresh and companion checks; practice data contracts; full local
offline checks; documentation links and whitespace. Real keyboard input and
Windows/Linux native GUI appearance remain manual acceptance.
