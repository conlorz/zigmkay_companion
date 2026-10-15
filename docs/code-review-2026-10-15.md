# Codebase review: dependencies, desktop integration and persistence

Reviewed on 2026-10-15 against published main
`c502c2ea9213e468651a15f43258b130a5f75b05` (typing tutor, PR #2).
This is a review and proposed follow-up plan; it changes no application behavior.
The review branch initially pointed at `7efa07a` and was fast-forwarded to this
published main commit before writing this report.

## What happened to DVUI?

**The application still uses DVUI. It was not replaced by SDL3.**

The current graph is:

```text
Editor / tutor / companion Zig UI
  -> DVUI widgets, layout and drawing
     -> SDL3 backend: windows, rendering and events
     -> FreeType: font rendering
  -> ztray: native tray integration
```

Evidence in this checkout:

- [Desktop graph](../packages/platform/desktop_build.zig): creates the `dvui`
  module from `src/dvui.zig`, imports DVUI's `src/backends/sdl.zig`, links SDL3,
  defines `DVUI_USE_FREETYPE`, and links FreeType.
- [UI helpers](../packages/desktop/src/ui.zig) and
  [practice UI](../packages/desktop/src/practice_ui.zig) import `dvui` directly.
- [Fonts](../packages/desktop/src/fonts.zig) also calls FreeType through DVUI.
  Removing FreeType therefore requires more than deleting a manifest entry.
- [Desktop pins](../tools/desktop_dependency_pins.zig) contains the immutable
  DVUI revision `9b372ab0e3beca5060eb1f9ffe3e83ee61665e37` and package hash.
  DVUI, ztray, SVG/TinyVG and icons are acquired separately, then adapted into
  caches by [source adaptation](../tools/desktop_source_adaptation.zig).
- [Root build](../build.zig) accepts those adapted source directories and
  assembles the modules itself. It bypasses upstream dependency build scripts.
  This is why SDL3 and FreeType appear in `build.zig.zon` while DVUI does not.

### When and why did dependency integration change?

The locally available extraction history contains commit
`1f81cb87783392ed0decd596c7d880d8c215fae8`, dated **October 11, 2026**,
"Complete offline flash and catalog contracts and port desktop dependency audit."
It introduced `packages/platform/desktop_build.zig`, source adaptation and DVUI
adaptation rules. Its historical S02 handover explicitly says this bypassed
incompatible original build scripts and unrelated transitive example graphs
while retaining DVUI on exactly Zig 0.17.0. It also explicitly left normal
release dependency packaging for subsequent work. That handover is historical
evidence accessible with `git show`, not a required external development input.

Published source commit
[`052ad80`](https://github.com/conlorz/zigmkay_companion/commit/052ad80),
dated **October 13**, already contains this arrangement. Thus it predates both
the October 14 Build/Flash PR and the tutor/SQLite PR. Public main begins with
the independent-source publication, so it does not expose the earlier
extraction commits as a normal chronological public history. The available
evidence identifies a change to dependency integration, not a switch away
from DVUI. It does not establish how a separate original repository was built
before extraction.

## SQLite and zqlite

SQLite was added to published main by
[`c502c2e`](https://github.com/conlorz/zigmkay_companion/commit/c502c2e),
"Add typing tutor with portable timing history, guided lessons and recall"
(October 14). It stores practice records and raw timing events.

The [manifest](../build.zig.zon) pins the SQLite 3.54.0 autoconf source archive.
The root build compiles `sqlite3.c` directly with project-owned flags.
[practice_database.zig](../packages/desktop/src/practice_database.zig) declares
the C ABI manually and implements statements, bindings, transactions, migrations
and backup integration. It is substantially more than a dependency declaration.

**Recommended direction: use zqlite for the Zig database API.** The verified
upstream head on review day was
[`865223b734a5113f731ab1eb1d7d81c8ac252913`](https://github.com/karlseguin/zqlite.zig/commit/865223b734a5113f731ab1eb1d7d81c8ac252913),
whose commit message is "zig 0.17". Both `master` and `dev` resolved to it.
However, its README and manifest still advertise 0.16.0. This report verifies
the revision and acquisition, not successful compilation or API compatibility
with exactly Zig 0.17.0.

Zqlite wraps SQLite; it still compiles the bundled SQLite C implementation by
default. Adopting it reduces our handwritten ABI/wrapper maintenance and makes
the Zig dependency explicit. It does not eliminate SQLite or C from the graph.
See the [upstream installation and API documentation](https://github.com/karlseguin/zqlite.zig/blob/865223b734a5113f731ab1eb1d7d81c8ac252913/readme.md).

## Major changes to schedule

P1 means address promptly for correctness or build reliability. P2 means
important architectural or coverage work. Source-reviewed findings below are
not presented as newly executed reproductions.

### 1. P1: reconcile the saved disk revision after an asynchronous save

**Source-reviewed correctness defect.** In
[project_files.zig](../packages/desktop/src/project_files.zig),
`Prepared.promote` rejects any result when the current document differs from
the captured document, before updating `model.saved_id`. The application also
validates the original action against the current model before promotion in
[main.zig](../apps/desktop/main.zig).

Trigger: disk and saved baseline are O; edit to A; start saving A; edit to B
while the worker runs. The worker successfully writes A. Delivery is rejected
as stale, leaving the saved baseline at O. The next save of B compares disk A
against expected O and returns `ExternalProjectChanged`, although this process
performed the write. Newer edits should remain dirty, but the acknowledged
on-disk revision still needs to advance to A for the same document/path owner.

Separate acknowledgement of completed filesystem effects from permission to
replace the current document. Preserve editor-generation and path checks so
an old save cannot alter a different document's baseline. Add a regression
covering O -> A -> in-flight save -> B -> successful second save. Existing
[file-worker tests](../tests/desktop_integration.zig) cover stale delivery, but
their stale-save cases save the initial baseline and miss this sequence.

### 2. P2: prevent concurrent project saves from silently losing an update

**Source-reviewed race.** `Request.prepare` in project_files.zig reads and
checks the old project digest, then separately calls `snapshot.save`.
[snapshot.zig](../packages/project/src/snapshot.zig) atomically replaces
`project.zon`, but there is no shared lock around the comparison and replacement.
Two application instances can both pass the comparison and then overwrite each
other. Atomic replacement prevents partial files; it does not serialize writers.

Introduce a per-project cross-process save lock, hold it across digest checking
and document publication, and re-read the digest after acquiring it. Keep source
bundles immutable. Test two writers starting from the same baseline: one save
succeeds and the other reports a conflict. Do not claim protection against
arbitrary external editors that ignore the lock.

### 3. P2: make DVUI a discoverable, conventional package dependency

**Architecture recommendation.** The application relies on a GUI toolkit that
is absent from its package manifest. Dependency ownership is split among the
manifest, desktop pins, root build, adaptation rules and repeated mise commands.
The current setup is explicit and hash-checked, but makes routine dependency
review and upgrades unnecessarily difficult.

Select and prove an immutable Zig 0.17-compatible DVUI package revision, then
declare it in the manifest and consume its exported backend module where
possible. If upstream still cannot support the required graph, retain a small,
documented compatibility layer with one authoritative pin source and explicit
tests. Do not merely insert the current historical pin and assume its upstream
build will work. Keep exactly Zig 0.17.0. Preserve SDL3/FreeType as required
backend dependencies, allowing upstream ownership where supported.

Acceptance: a documented source build needs no manually selected DVUI source
directory; dependency acquisition is reproducible; the offline desktop fixtures
still exercise text, fonts, icons and child windows.

### 4. P2: replace the handwritten SQLite wrapper with pinned zqlite

**Requested dependency direction and maintenance recommendation.** Prove the
selected zqlite revision with Zig 0.17.0 before changing the manifest. Replace
the manual statement/open/binding layer while retaining application-owned
schema validation, cohort keys, transactional migrations, collision detection
and import/export behavior. Keep any necessary backup API adapter narrow if
the selected wrapper does not expose it.

Preserve the current SQLite hardening flags and bounds deliberately; do not
assume the wrapper defaults reproduce them. Check SQLite-version differences,
Windows linkage, Unicode paths, concurrent writers, read-only errors, schema
1/2/3 migration, legacy import receipts and WAL-safe standalone export. Existing
practice database tests provide meaningful regression coverage to carry forward.
Do not rewrite users' databases just to change the API wrapper.

### 5. P2: make the desktop platform boundary and CI coverage agree

**Confirmed source-level platform restriction.**
[sdl_build.zig](../packages/platform/sdl_build.zig) panics on every non-macOS
target with "Native USB acceptance currently supports only macOS".
The shared desktop graph calls it unconditionally for SDL3. Therefore this
restriction affects the GUI dependency/build path, not only USB acceptance.
The README acknowledges incomplete platform acceptance; this is a concrete
reason desktop builds cannot currently establish that acceptance elsewhere.

Scope the five macOS config-header adjustments to macOS, and give other platforms
their own validated build paths or a clear documented desktop support limit.
Then add GUI compile/link jobs and suitable offline fixtures to CI. Current
[offline CI](../.github/workflows/offline-checks.yml) checks Linux contracts;
[practice CI](../.github/workflows/practice-contracts.yml) checks storage and
metrics on three hosts. Neither builds the real DVUI/SDL3/tray application.
Add a macOS desktop build gate first, then expand as platform support is proven.
No hardware access is needed for compilation or SDL dummy fixtures.

### 6. P2: distinguish history viewing from writable migration/setup

**Source-reviewed behavior and product recommendation.**
[practice_history.zig](../packages/desktop/src/practice_history.zig),
`Request.prepare`, always opens an existing history directory's database with
`readonly=false`, even for a refresh without a save, clear or import.
[Database.open](../packages/desktop/src/practice_database.zig) then starts an
immediate transaction, may migrate, and configures WAL. Viewing an existing
read-only history can fail, and refreshes compete for write access with other
instances. A missing history directory is handled separately without creation.

Make initial creation/legacy migration an explicit writable phase, then use a
read transaction for a query's consistent snapshot. Preserve automatic migration
where intended, with a readable error and recovery path if writing is unavailable.
Test refresh from an existing read-only current-schema database and concurrent
refresh/save without requiring every reader to take the writer lock.

## Minor changes

1. **Centralize repeated desktop pins and source arguments.**
   [mise.toml](../mise.toml) repeats four long content-addressed package paths
   across many commands. The adaptation tool also repeats DVUI/ztray hashes
   already in desktop_dependency_pins.zig. Derive command inputs from the
   acquisition receipt and import pin constants from one place. A version bump
   should not require synchronized edits across unrelated commands.
2. **Separate build configuration from application orchestration.** Root
   build.zig exceeds 1,100 lines, and apps/desktop/main.zig exceeds 2,300 lines.
   Extract cohesive build helpers and startup/tutor/file-effect coordination
   behind existing module contracts. Keep hardware authorization visible at the
   effect boundary. This is maintenance work, not evidence that size alone is a
   correctness bug.
3. **Audit duplicate keymap implementations.** Both
   [packages/keymap](../packages/keymap) and
   [packages/input-source](../packages/input-source) contain KeyMap,
   HID conversion and platform bridges; root build still references both.
   Identify intentional API differences and converge shared Zig logic before
   they drift. Preserve imported C bridges rather than expanding them.
4. **Correct obsolete module descriptions.** practice_history.zig still opens
   by describing per-run files, although the active worker uses SQLite and
   imports legacy files. desktop_build.zig describes itself as a compile-only
   audit graph although its returned modules build the shipping source app.
   Document the current ownership and compatibility rationale in the developer
   guide so readers do not need historical handovers to understand dependencies.

## Validation and unresolved acquisition issue

The shell default was Zig 0.16.0; all checks below explicitly selected
`/Users/clorz/.zvm/0.17.0/zig`, verified as exactly `0.17.0`.

| Check | Result |
| --- | --- |
| `zig build check -j2 --test-timeout 30s` on initial `7efa07a` | Passed; predates tutor/SQLite changes |
| `zig test packages/desktop/src/practice_results.zig` on reviewed main | All 24 tests passed |
| `zig build check -j2 --test-timeout 30s --summary all` on reviewed main | Blocked during SQLite package acquisition |
| Practice-data and app-paths build tests on reviewed main | Blocked by the same hash mismatch, including with selected separate cache directories |
| Direct SQLite archive fetch, including a dedicated cache | Returned the declared package hash |
| Pinned zqlite acquisition | Succeeded; wrapper compilation and migration integration remain untested |

The build reports declared SQLite hash
`N-V-__8AAKEJxgAqL7tBBStLJr_SloDtRVAE49PAFiABzwky`, but fetched hash
`N-V-__8AAKEJxgBNgi0a2esHEp84CYcHMiwsvz3R_WeQjKnn`. Direct `zig fetch`
of the manifest URL returns the declared hash, so **this is not sufficient
evidence that the committed pin is wrong**. Investigate acquisition/extraction
and local cache behavior before claiming clean-build reproducibility or replacing
the hash. No existing package caches were deleted and no dependency pin was
changed during this review. The full reviewed-main test suite is not certified
by the passing pre-tutor check or standalone test.

No GUI was launched and no keyboard was accessed. Historical extraction commits
were inspected read-only; no sibling repository or additional clone was needed.

## Proposed implementation order

1. Resolve the fetch/build disagreement and establish a passing current-main
   baseline; reproduce and fix the asynchronous-save baseline case.
2. Add project save locking and its two-writer regression.
3. Migrate the database API to pinned, compiler-tested zqlite in a separate PR.
4. Normalize DVUI dependency ownership, scope platform adaptations correctly,
   and add real desktop CI gates.
5. Separate history reads from writes, then perform the smaller deduplication
   and documentation work above.

Each implementation PR should carry its own focused validation. This review PR
does not authorize device operations or release publication.
