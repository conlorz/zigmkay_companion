# Package F: deliberate help and recall review

Hint policy v1 supports full guidance, delayed hints and hints on request alongside
layout-only and hidden practice. Delay includes ready-time hesitation, excludes
pauses, resets for each focused position and can adapt to matching clean character
medians. A DVUI timer wakes idle frames when the delay expires. Explicit requests
remain available during hidden recall. Hints use keyboard highlighting with a
constant keyboard rectangle, a cyan Hold / amber Tap legend and small footer
connection details. Instruction paragraphs were removed following manual feedback.
Opposite-hand home-row
Shift is preferred only when supported by metadata.

New runs retain actual rendered cue episodes, requests, per-attempt visibility,
per-character cued/uncued opportunities and clean uncued occurrences. These mean
shown/not shown, not proof the learner noticed a cue. Hint markers do not reset
motor interval anchors. Requested assistance in hidden practice has a separate
comparison cohort. Old payloads retain unknown cue evidence rather than acquiring
invented unaided success. Bounded/truncated capture is excluded from recall.

Optional review aggregates the same behavior, mapping, input source, text family
and verification state across lesson contexts. Qualified recall requires hidden
practice, no revealed help, positive duration, five clean uncued occurrences and
at least 97% uncued first-pass success for that character. Batch/repeat/paste
exposure cannot supply clean intervals. Suggested 1/3/7/14-day intervals are an
initial policy, not a validated forgetting model. Review starts a hidden targeted
lesson with familiar surrounding content; unavailable targets explain why a
matching lesson is needed. Help is always available and progression is voluntary.

Schema 3 adds event visibility under the existing immediate transaction. Readonly
schema 1/2/3 imports remain supported; old serialized bytes and indexed cohort
identities remain stable. Semantic duplicate timing comparison accepts missing
new defaults without rewriting old evidence. Enlarged run queues and history
pages are heap-owned to avoid excessive stack frames.

Review checked paused/idle timing, request resets, cue attribution, old evidence,
future/stopped/truncated runs, batch-only exposure, cohort separation, migration
and owned allocation cleanup. It corrected stale recommendations after a context
switch, clipped review explanations and hint settings overlapping at the minimum
window height. Settings now scroll independently. A native CI failure also
exposed journal-mode contention during concurrent first opens; bounded retries
cover SQLite's immediate BUSY return without changing transaction semantics.
Native wide/small help,
settings, review and requested-help rundown were manually compared with the F
mockup using explicit offline cache fixtures. Subsequent manual feedback removed
the contextual explanation so revealing a hint cannot resize or move the keys.
Screenshots are linked from the tutor guide; no screenshot assertion test was
added. Keyboard ergonomics and cross-platform native GUI behavior remain manual
acceptance.
