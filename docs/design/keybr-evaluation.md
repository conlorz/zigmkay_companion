# keybr.com evaluation: integrate or port adaptive typing practice

Date: 2026-11-18. Reviewed keybr revision:
[`05a37bc5265f65ff538c59c613db29442f345d51`](https://github.com/aradzie/keybr.com/tree/05a37bc5265f65ff538c59c613db29442f345d51)
(`master`, committed 2026-09-28). The companion baseline is `companion-next` at
`0a70080`. This is an engineering assessment, not legal advice.

## Summary

[keybr.com](https://github.com/aradzie/keybr.com) teaches touch typing with
adaptive lessons. It starts with six frequent letters and measures how fast you
type each one. It focuses the weakest letter, and it unlocks the next letter
only when every unlocked letter reaches a target speed. Lesson text is made of
pronounceable pseudo-words from a character Markov model, or of real words that
use only the unlocked letters.

**License verdict:** keybr is AGPL-3.0. The companion is GPL-2.0 *only*. These
licenses are incompatible, so neither keybr's code nor its derived data files can
ship in or with the companion. Ideas, algorithms and published behavior are not
protected by copyright and can be reimplemented independently.

**Recommendation:** port the ideas to Zig with a clean-room design. Do not embed
or translate keybr. Phase 1 of that port is implemented on `companion-next`: the
new **Adaptive keys** lesson stage, pseudo-words, per-letter confidence and
unlocking (see [Implemented](#implemented-phase-1)).

## How keybr works

These are the behaviors we used. The [package notes](#keybr-package-map) say
where each one lives in keybr.

### Language model and pseudo-words

- **Training.** An offline generator reads a frequency list per language. It
  keeps the 10,000 most frequent valid words. Each word of three or more
  letters is fed to the model in proportion to its frequency.
- **Model.** A fourth-order character Markov chain: three characters of
  context predict the next one. A space marks the word boundary.
- **Storage.** Each context's transitions are scaled to weights summing to 255.
  The result is stored in a compact binary file, `model-<lang>.data`; English is
  about 47 KB.
- **Generation.** Each word is drawn character by character from the
  distribution for its context.
  - Letters that are not unlocked are removed.
  - The end of a word is impossible before three letters. After that it becomes
    more likely with every letter.
  - A focused letter is forced by starting the word from a known prefix that
    ends in that letter.
  - A per-language blocklist rejects offensive words.
- **Letter order.** The unlock order comes from the model's letter frequencies.
  For English it is `e n i a r l t o s u d y c g h p m k b w f z v x q j`. An
  option orders letters by keyboard row instead.

### Guided lesson: unlocking and focus

- **Start.** Six letters are always unlocked.
- **Unlocking.** The next letter unlocks when every included letter's
  confidence is at least 1.0. By default this uses *best* confidence, so a slow
  day does not lock letters again. A letter that is already confident from
  other practice is included wherever it sits in the order.
- **Focus.** The included letter with the lowest confidence below 1.0 is
  focused. A letter with no data counts as zero, so a newly unlocked letter is
  focused first.
- **Text.** Lessons are about 100–200 letters. Real words that use only the
  included letters and contain the focused letter are used when at least 15
  exist; otherwise the pool is padded with pseudo-words.

### Per-key statistics and confidence

- **Timing.** Time to type is the interval since the previous input event.
- **Errors.** A position typed wrong before being typed right is a miss.
- **Lesson histogram.** For each character, a lesson records hits, misses and
  the mean time of the error-free occurrences. Implausible means are discarded.
- **Smoothing across lessons.** Each key's lesson means are smoothed with an
  exponential moving average, α = 0.1. The best smoothed value is also kept.
- **Confidence** is target time divided by smoothed time, and **best
  confidence** uses the best time. The target time is 60,000 / target CPM. The
  default target is 175 CPM, which is 35 WPM or about 343 ms per key.
- Misses do not reduce confidence directly. They only remove samples from the
  mean.
- **Forecast.** A polynomial regression over the recent lesson speeds
  estimates the learning rate and how many lessons remain to reach the target.
  It is only shown when r² ≥ 0.5.

### Results, layouts and storage

- **Score** combines speed, distinct characters, errors and length.
- Daily goals, accuracy streaks and summary statistics are shown on top.
- **Layouts** map browser key codes to characters for 100+ OS layouts. They
  restrict the alphabet and draw the on-screen keyboard. Statistics are grouped
  by layout family.
- **Storage.** Results are stored in a compact binary format, in IndexedDB for
  guests.

For zigmkay, keybr's layout and geometry data is irrelevant. The companion
already has proven routes, layers and physical geometry from the firmware
project, which is more precise than an OS layout table.

## What the companion already has

Before this work, typing practice already had a lot of keybr's measurement
foundation. The full behavior is in the [user guide](../typing-practice.md).

| Capability | Companion | keybr |
| --- | --- | --- |
| Per-character timing | Raw event payloads; per-run median of *clean* intervals that exclude correction, paste, batch, repeat and first-input events | Mean of error-free intervals per lesson |
| Errors | First-pass success per occurrence, substitutions, retries | Hit/miss per character |
| Lessons | Six manual curriculum stages from Find keys to Real text, readable vocabulary words, weak-spot drills, recall review | Guided adaptive lessons, word lists, books, custom text, numbers, code |
| Advancement | Evidence checklist (opportunities, first-pass success, runs, timing calibration); learner-controlled | Automatic, driven by speed |
| Layout knowledge | Proven routes for layers, Shift, AltGr and hold providers from firmware | OS layout tables |
| Storage | SQLite with cohorts, migrations, import and export | IndexedDB or server |

What was missing: a speed target, a per-letter confidence estimate across runs,
automatic letter unlocking, a focus letter and a pseudo-word generator.

## Integration options

| Option | What it means | Language rule | License | Integration value | Verdict |
| --- | --- | --- | --- | --- | --- |
| A. Webview of keybr.com | Open the public website in an embedded browser | Needs a webview dependency and JS (needs permission) | No code distributed; just a website | No access to routes, layers, history or offline use | Not worth it; at most a documentation link |
| B. Bundled self-hosted keybr in a webview | Ship keybr's built web app with the companion | JS/TypeScript, Node build tooling (needs permission) | AGPL-3.0 distribution beside a GPL-2.0-only program; possibly "aggregation", but with AGPL source and network obligations | Separate UI and data; duplicates our storage | Rejected |
| C. Embedded JS engine (for example QuickJS) running keybr's lesson packages | Call keybr functions from Zig in-process | C engine plus JS (needs permission; expands C bridges) | One combined work containing AGPL code: incompatible with GPL-2.0-only | Packages are private ESM TypeScript and also pull in React | Rejected |
| D. WASM build | Compile keybr logic to WASM and host it | No WASM toolchain exists for this TypeScript | Same combined-work problem as C | High effort | Rejected |
| E. Data-only reuse | Load `model-<lang>.data` or the word lists | Zig loader possible | Derived from dictionaries of unknown provenance, distributed under AGPL as part of the repo; no clear separate license | Medium | Rejected |
| F. Clean-room Zig port of the ideas | Reimplement the behaviors with our own design, data and constants | Zig only | Ideas are not copyrightable; our own expression stays GPL-2.0 | Integrates with existing evidence, routes and storage | **Recommended** |

keybr is a web service with a Node server, webpack and React. None of its
packages are published or built as standalone libraries. Its core logic still
imports React and react-intl for formatting. Options B to D would add a second
language runtime, a large dependency closure and a parallel data model. They
would also lose the companion's main advantage: knowing exactly which firmware
route produces each character.

## License analysis

**keybr.**
- `/LICENSE` is the GNU Affero General Public License version 3, and
  `/README.md` says AGPL v3.0. The root `package.json` says `"GPL-3"`, which
  is inconsistent with that but also a GPLv3-family license.
- The copyright holder is Aliaksandr Radzivanovich.
- Source files have no per-file headers.
- Some bundled third-party material has its own licenses: CLDR keyboard data
  (Unicode license), two MIT-licensed math files and fonts.
- The word-frequency dictionaries that generate the language models and word
  lists have no stated source or license.

**Companion.** `LICENSE` is the GPL version 2 text, and the README says "GNU
General Public License, version 2" with no "or any later version" grant. The
companion is therefore GPL-2.0-only.

**Compatibility.**
- GPL-2.0-only code cannot be combined with GPLv3 or AGPLv3 code. GPLv2 §6
  forbids further restrictions, and the v3 licenses add terms that v2 does not
  allow. AGPLv3 §13 can only be combined with GPLv3, not v2.
- This rules out copying, translating or linking keybr code into the companion,
  and it rules out shipping keybr's derived data files.
- A line-by-line translation into Zig would be a derivative work, so it is
  excluded as well.
- Relicensing the companion as "GPL-2.0-or-later" would not help either. That
  would need every contributor's consent, and the combination would then be
  AGPLv3 as a whole.

**What is usable.**
- Ideas, algorithms, formulas and observable behavior are not protected. This
  rests on 17 U.S.C. §102(b) and Article 1(2) of the EU Software Directive
  2009/24/EC.
- Our reimplementation may therefore adopt these concepts:
  - six starting letters;
  - unlocking when all letters reach a target;
  - focusing the weakest letter;
  - confidence as target time divided by smoothed time;
  - character n-gram pseudo-words.
- A default 35 WPM target is an ordinary convention, not protected
  expression.
- The data file format and the word lists are not needed at all.

**Clean-room procedure followed.**
1. A separate research agent read keybr through `gh` into a scratch directory
   outside the repository and ran none of its code.
2. That agent returned a prose description of the behavior, with no code.
3. The Zig implementation was written from that description and the
   companion's own design. No keybr file, identifier structure, constant table
   or data was copied or translated.
4. Where the companion deliberately differs, the
   [design comparison](#implemented-phase-1) below records it.
5. Nothing from keybr is vendored, and no new dependency was added.

## Recommendation

Port, do not integrate.
- Keep one tutor, one storage model and one language.
- Use keybr as an inspiration for *adaptive pacing*.
- Keep the companion's stricter evidence rules: clean intervals, cohorts and
  first-pass success.
- Keep its routing advantages: layers, holds and modifiers.
- Do not reproduce keybr's breadth (books, quotes, 34 languages, code
  grammars). Those parts are large, data-heavy and need separate license-clean
  sources.

## Implemented (phase 1)

Commits on `companion-next`:

1. `22cf033` *Add adaptive letter lessons with pseudo-words and letter confidence*
2. `002d777` *Offer adaptive key lessons from per-letter history*: the
   curriculum stage, history model, tutor wiring, Lessons panel and gallery
   scenes
3. `c6dff2f` *Document the keybr evaluation and adaptive key lessons*
4. `79199c3` *Block unwanted pseudo-words and forecast runs to the target*
5. `9248c64` *Name the next adaptive letter in the rundown*
6. *Record adaptive practice limitations and validation*

### Pseudo-words: `src/desktop/practice_phonetic.zig`

- **Model.**
  - Letter-trigram model (two letters of context plus a word boundary).
  - Trained at compile time from the first-party
    [practice vocabulary](../../src/desktop/practice_vocabulary.txt): 893
    words, each counted once.
  - Integer counts and integer weighted sampling over SplitMix64, so a seed
    reproduces the same text on every platform.
- **Generation.**
  - Only letters in the unlocked set are drawn.
  - When the trigram context has no allowed successor, it backs off to the
    bigram context, then to a uniform choice.
  - Words are 3–9 letters.
- **Focus.** Up to sixteen candidates are drawn until one contains the focus
  letter, ends naturally and differs from the previous word. Otherwise a word
  starting with the focus letter guarantees coverage.
- **Blocklist.** A short first-party list of whole words is never offered,
  because letter models can assemble profanity from harmless vocabulary.
- **Differences from keybr:**
  - lower model order;
  - our own small corpus, unweighted;
  - rejection sampling instead of prefix tables;
  - no growing end-of-word factor, but a hard length limit.

### Per-letter confidence: `src/desktop/practice_keys.zig`

- **Observations.** Each scored, completed run contributes one observation per
  letter: its median clean interval (from the existing timing payloads) and
  its first-pass miss rate.
  - Truncated or count-only runs keep accuracy but not timing.
  - Fewer than three clean samples in a run do not update timing.
- **Smoothing.**
  - Exponential smoothing with weight 0.25 for the newest run.
  - Runs here are longer than keybr's lessons and happen less often, so the
    estimate should react within a handful of runs.
  - The best smoothed interval is kept.
- **Known letters.** A letter needs two timed runs to count as known.
- **Confidence** is target interval divided by smoothed interval, and best
  confidence uses the best interval. The target is chosen in WPM (20–60, default
  35), at five characters per word.
- **Accuracy matters**, unlike keybr: a letter whose smoothed miss rate is above
  5% is neither *confident* nor *reached*.
- **Forecast.**
  - A least-squares line through a letter's newest ten smoothed speeds
    estimates how many more runs it needs to reach the target.
  - The forecast needs at least four runs, an upward slope and r² ≥ 0.5, and
    it is hidden beyond 50 runs.
  - The Lessons panel shows the forecast for the focused letter.
  - keybr fits higher-degree polynomials over a detected session; this is a
    simpler independent choice.
- **Evidence.**
  - The model uses the newest 60 scored, completed runs of the same *practice*:
    board behavior, input mapping, OS/draft source, English family and
    verification state.
  - It spans every preset, stage and assistance level. Learning state should not
    restart per cohort, while comparisons and trends keep their strict cohorts.
  - The history worker builds the model on the background thread
    (`practice_history.zig`).

### Adaptive planning and text: `src/desktop/practice_adaptive.zig`

- **Unlocking.**
  - Letters unlock in the layout's reachable base-layer order. That order comes
    from the existing curriculum, `enaritoslcdumpghbyfvkwzxjq`, minus
    unreachable letters.
  - The plan starts at six letters, or at the lesson's frozen alphabet size if
    that is larger.
  - It adds a letter while every unlocked letter has *reached* the target (best
    confidence ≥ 1 and accurate).
  - Unlocking is a contiguous prefix of the order; keybr also includes any
    already-confident letter. A frozen alphabet is never reduced, so a poor run
    never demotes the lesson.
- **Focus.**
  - The first letter without enough evidence (usually the new one) is focused.
  - Otherwise the lowest current confidence is focused, with inaccuracy
    treated as slowness.
  - When everything is confident, the slowest letter keeps the focus instead of
    none being selected.
- **Text.**
  - Short, Normal and Long lessons are 15, 30 and 60 words.
  - Every word contains the focus letter (or the review target).
  - Every third word is a vocabulary word made only of unlocked letters and
    containing the focus, when one exists; the rest are pseudo-words.
- **Versioning.** Generation is versioned separately (adaptive v1) and frozen
  by a literal SHA-256 test.

### Curriculum, storage and UI

- **Curriculum stage.** `Stage.adaptive` ("Adaptive keys", stage 7) is
  appended to `practice_curriculum.Stage`.
  - Its frozen context reuses existing fields: `alphabet` is the unlocked count
    and `family` is the focus index.
  - Validation rejects a focus outside the alphabet.
  - No new record or context fields were added. Adding fields would change the
    serialized cohort keys of every historical curriculum run.
  - Old records, fixtures and migrations are untouched; new records simply use
    the new enum tag.
- **Controller.** `Controller.adapted` applies the plan whenever an adaptive
  lesson starts or is previewed. This includes *New exercise*, so every run
  re-plans from the newest history.
  - The plan is then frozen in the run's cohort, so the run stays
    reproducible.
  - `Tutor.zig` copies the history's letter model into the controller only when
    the loaded history belongs to the same practice.
- **Lessons panel.**
  - Shows every reachable letter with its confidence percentage, state ("new",
    "locked") and colour: amber for focus, green for confident.
  - Has a target speed selector and an explanation of the current plan.
  - Manual alphabet controls stay in the other stages.
  - The target speed lasts for the editor session, like the daily goal choice.
- **Review lessons** reuse the adaptive context with their recall target as
  the focus.
- **Rundown.** After a scored adaptive run, the coaching line names the
  letter that the next lesson unlocks or focuses, using the newest loaded
  estimates.
- **Gallery.** The offline `--native-layout-curriculum-frames 132` gallery
  adds scene 19 (adaptive, wide) and scene 20 (narrow), with a synthetic
  letter model. Scenes 21 and 22 complete an adaptive run and show the
  rundown's unlock notice.
- **Samples.** `practice-samples` prints adaptive lessons for 6, 7, 10, 16 and
  26 letters.

### Validation

All offline:
- `zig fmt --check build src tools tests`
- `zig build check test`
- `zig build test-practice -Donly=practice`
- `zig build test-desktop -Ddesktop` (offline GUI fixtures)
- `zig build check -Ddesktop`: the new UI compiles. Its only failure at the
  time came from another thread's in-progress changes, which
  `tools/desktop_physical_smoke.zig` exposed.
- The offline native gallery (`--native-layout-curriculum-frames 132`) captured
  the [adaptive panel](../screenshots/typing-practice/adaptive-wide.png).

New tests cover:
- model training, letter restriction, focus coverage and reproducibility;
- smoothing, best value, sparse timing, truncation and the miss threshold;
- unlocking, no demotion and focus selection;
- lesson composition, frozen hashes and controller freezing;
- history aggregation across cohorts of one practice, excluding stopped runs.

No human typing trial has validated the constants yet.

### Known limitations

- **Older builds.** A build without the adaptive stage cannot decode records
  whose stage is `adaptive`. It reports them as rejected history and leaves
  them unchanged, as it does for other unknown records.
- **Target speed.** The target is not saved yet. A new editor session starts
  at 35 WPM.
- **History refresh cost.** Every refresh decodes the timing payloads of up to
  60 more runs to build the letter model. This happens on the background
  worker, alongside the existing progress summary.
- **Stale estimates.** The plan uses the newest *loaded* history. Pressing
  **New exercise** before the just-finished run's save and refresh complete
  plans from the previous estimates.
- **Letters only.** Unlocking is a contiguous prefix of the layout's letter
  order, and adaptive lessons contain lowercase letters only.

## Phased plan

1. **Phase 1, done:** adaptive letter stage, pseudo-words with a blocklist,
   per-letter confidence and forecast, target speed, history model, Lessons
   panel, rundown notice, gallery scenes, documentation.
2. **Phase 2, polish (small):**
   - Persist the target speed in preferences.
   - Show per-letter confidence in Progress and the rundown heatmap.
   - Offer a keyboard-order option that unlocks home-row letters first, using
     the existing `KeyMetadata.home_row` from project geometry.
3. **Phase 3, zigmkay-specific adaptivity (medium):**
   - Extend adaptive unlocking from letters to Shift outputs, layer outputs and
     modifier families, using the existing route proofs. This is where zigmkay
     can surpass keybr: unlock symbols on layer 1 only after the base letters
     are fluent.
4. **Phase 4, content (needs a license review):**
   - Train the model on a larger, license-clean English word-frequency list,
     weighted by frequency.
   - The source must be compatible with GPL-2.0-only. For example, CC BY-SA
     material is not, while public-domain or permissive lists may be.
   - Additional languages would follow the same rule.
5. **User validation:** tune the smoothing weight, the minimum runs and samples,
   the 5% miss threshold and the lesson lengths from real typing sessions.

## keybr package map

Behaviors above were taken from these packages of the reviewed revision:

- `keybr-phonetic-model`: model, generator, binary format and blocklist.
- `keybr-generators`: training from dictionaries.
- `keybr-lesson`: guided lesson, confidence, target, forecast and settings.
- `keybr-result`: per-key statistics, smoothing, units and score.
- `keybr-textinput` and `keybr-textinput-events`: steps, histograms and time to
  type.
- `keybr-keyboard`: layouts and geometry.
