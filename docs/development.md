# Development guide

Start with the [README](../README.md#get-started-with-mise) for installation.
This checkout contains the editor, resident companion, native UI, utilities and
tests. First-party implementation uses exactly Zig 0.17.0; imported C bridges
retain their existing scope. Follow [AGENTS.md](../AGENTS.md) when contributing.

## Everyday commands

Run commands from the repository root. `mise run` selects the pinned tools;
shell activation is optional.

| Command | Purpose |
| --- | --- |
| `mise run check` | Check bootstrap and compiler pin without devices |
| `mise run test` | Run the offline companion checks |
| `mise run editor:build` | Compile the native application without launching |
| `mise run editor:test` | Run offline GUI launch, tutor, source-refresh and companion fixtures |
| `mise run companion:test` | Check companion visibility and placement offline |
| `mise run typing-practice:test` | Check practice data, storage and application paths |
| `mise run editor` | Launch the editor with automatic keyboard monitoring |
| `mise run companion` | Launch the tray resident with windows hidden and automatic monitoring |

For a GUI session without keyboard monitoring or automatic Build/Flash setup:

```sh
mise run editor -- -- --offline
```

The two `--` separators forward arguments through mise and `zig build` to the
application. Closing the editor can leave the tray resident alive; choose
**Quit Zigmkay** to exit. An offline session never authorizes a device transfer.

GUI tasks prepare missing pinned desktop sources under `.zig-cache/` before
compilation. Acquisition needs network access; the checks themselves do not
access keyboards. Keep test outputs in caches, and preserve personal projects
and attached source bundles.

## Source map and further reading

| Location | Responsibility |
| --- | --- |
| [apps/desktop](../apps/desktop) | Application startup, resident lifecycle and background build/flash work |
| [packages/desktop](../packages/desktop) | Editor models, native UI, companion presentation and tutor |
| [packages/project](../packages/project) | Project schema, validation, source preservation and export |
| [packages/session](../packages/session) | Device sessions and verified live state |
| [packages/jobs](../packages/jobs) | Build environments, managed jobs and Flash tooling |
| [packages/catalog](../packages/catalog) | Pinned firmware board/default-profile inventory |
| [packages/platform](../packages/platform) | Desktop integration, user paths and native window support |
| [tools](../tools) / [tests](../tests) | Zig utilities and integration contracts |

- [Typing practice user guide](typing-practice.md): controls, metrics, data and evidence.
- [Tutor package design](design/typing-practice-packages.md): boundaries and contracts.
- [Practice implementation](implementation/typing-practice.md): input and scoring.
- [Practice data](implementation/practice-data.md), [rundown](implementation/practice-rundown.md),
  [progress](implementation/practice-progress.md), [timing diagnostics](implementation/practice-diagnostics.md),
  [curriculum](implementation/practice-curriculum.md), and [help/recall](implementation/practice-help.md).
- [Native layout review](implementation/practice-layout-review.md): visual studies,
  native screenshots, layout checks and offline gallery reproduction.
- [README screenshot notes](screenshots/overview/README.md): native capture provenance.
- [Compatibility status](../compatibility/README.md): remaining acceptance gates.

## Build and check

Use exactly Zig 0.17.0 (`.zigversion` and `mise.toml`). Verify your compiler with
`zig version` before running these commands. The normal dependency is an
immutable, hash-pinned EuroZig firmware PR-head revision pending merge; the
normal source build does not require a sibling firmware checkout. Fetching missing
pinned source archives may require network access during dependency acquisition.

```sh
zig build test
zig build check
```

These checks do not access devices. An explicit `--fork <firmware-checkout>`
override is available for local firmware development, but is not required for
normal builds and is not a release dependency. `firmware-check` and
`catalog-firmware-check` are opt-in firmware compilation checks; they do not
flash hardware.

## Capabilities and limits

Project validation reads data without compiling callbacks. Export and firmware
compilation require supported source and ABI bindings; callback-bearing defaults
need an explicit source binding. Catalog fixtures and processor checks cover
all 14 selected boards, including offline default-profile source/export checks;
physical GPIO mapping and per-board hardware acceptance remain separate. Native layout tests can query the host desktop
layout and are distinct from deterministic keymap tests. Compatibility and
native platform acceptance remain incomplete; do not interpret a passing
`zig build check` as device or cross-platform certification.

Normal editor startup monitors keyboards. Builds, tests and explicit offline
startup do not access hardware. Flashing or other hardware mutations require a
separate explicit hardware task. No preparation step below launches a GUI or
flashes a device.

## Editor Build and Flash

Normal source-built editor startup automatically prepares Build and Flash in
the background. `mise run editor` only launches the application; no firmware
configuration flags or manual receipt generation are needed. The application
uses the exact Zig 0.17.0 compiler that built it, its owning companion source
tree, and the immutable firmware pin. First use may download pinned packages
and compile Flash tools; the system-message bar shows preparation status. Prepared inputs
are cached under the application's cache directory. Preparation never accesses
a device or flashes firmware. Failed preparation offers **Retry setup**.

Once ready, **Flash** builds the current project if necessary, enters BOOTSEL,
transfers the verified UF2, and waits for coherent reconnection. Only that
explicit click authorizes transfer; startup and edits do not. **Auto-build** is
optional and does not authorize flashing. Normal Flash progress stays in the
system-message bar; a separate window opens only for errors. If BOOTSEL is not
discovered within five seconds of the HID trigger, the bar asks the user to
enter BOOTSEL manually and allows thirty additional seconds. That is the same
authorized transaction, not another transfer attempt. No automatic retry occurs.
Full provenance audits are off by
default. Automatic setup skips companion package-tree and archive audits, while
retaining Zig's pinned package-hash checks during acquisition. **Debug** deep
audits require an explicitly audited developer environment; automatic inputs
report `PackageAuditNotCaptured` rather than claiming audited provenance.
Explicit offline startup and tests do
not run automatic preparation. Explicit prepared-config/tool arguments remain
developer overrides. These source-build inputs require the compiler and owning
source tree to remain available; this is not a self-contained release bundle.

## Developer preparation

Optional desktop source acquisition is separate from normal checks:

```sh
zig build prepare-desktop-dependencies \
  -Ddesktop-acquisition=true -Ddesktop-source-cache=<absolute-cache-directory>
```

The resulting `source-inputs.zon` records verified immutable sources for explicit
development audits. Normal desktop builds acquire and adapt their sources
automatically; no source-directory arguments are required:

```sh
zig build build-desktop -Ddesktop-dependencies=true -Ddesktop-vectors=true
zig build check-desktop-dependencies -Ddesktop-dependencies=true -Ddesktop-vectors=true
```

The manifest's `dvui` dependency is a local
[compatibility package](../packages/dvui/build.zig). Its
[source manifest](../packages/dvui/sources.zon) is the single authority for pinned
DVUI, ztray, SVG/TinyVG and icon revisions and hashes. Their retained upstream
build scripts predate the required Zig 0.17 build APIs. The compatibility layer
verifies immutable sources and applies counted Zig adaptations to generated cache
copies, preserving the imported C and Objective-C sources. DVUI remains the UI
toolkit; SDL3 supplies its window/rendering/input backend and FreeType supplies
font rendering. Explicit absolute `desktop-*-source` overrides remain available
for development audits and must match the pinned hashes.

Native desktop CI compiles and links the real application on macOS, then runs
SDL dummy/software fixtures without keyboard access. The macOS SDL config
adjustment is scoped to that platform; full Linux and Windows desktop/tray
acceptance remains pending. Portable storage and keymap contracts have separate
checks. A passing portable test does not establish GUI support on those hosts.

Practice persistence uses the immutable `zqlite` dependency declared in
`build.zig.zon`, including its bundled SQLite implementation. Application code
owns schema validation, transactions and migrations; the translated upstream
header is used only for SQLite's online backup integration and journal-mode
retry handling. Current-schema history queries use a read-only connection and
one read transaction. Legacy imports and schema upgrades reopen for writing
only when needed.

Project saves retain a `.project.lock` file in the project directory. Cooperating
instances hold its OS lock while checking the saved digest and publishing the
document; the file must not be removed while an instance may hold it. Atomic
source bundles remain immutable. A completed background save advances the disk
baseline even if newer editor changes remain dirty.

Selected toolchain preparation and verification require explicitly owned caches:

```sh
zig build prepare-toolchain-installation \
  -Dtoolchain-compiler=<absolute-zig-executable> \
  -Dtoolchain-distribution=<absolute-distribution-directory> \
  -Dtoolchain-receipt-cache=<absolute-owned-cache>
zig build verify-toolchain-receipt \
  -Dverify-toolchain-cache=<absolute-owned-cache>
```

Preparation verifies the selected compiler distribution; receipt verification
rechecks recorded bytes without executing the compiler. Neither downloads a
toolchain or builds firmware.

Package inventory, offline source import, dependency resolution and build
environment preparation are explicit operations with caller-selected absolute
plan and cache paths. Missing prepared sources fail resolution; network
acquisition through these developer commands requires an explicit preparation-plan
opt-in. Normal checks and explicit offline startup never run these operations.
Normal editor startup instead owns automatic preparation as described above.
A prepared environment can still be selected at application launch using
`--prepared-build-config <absolute-file>`.

Manual Flash-tool preparation (`prepare-picotool -Dflash-tools=true`)
requires a compatible firmware wrapper and pinned source revision. It installs
verified tools into a selected cache prefix, not onto a device. Physical
picotool acceptance and desktop flash integration remain separate gates.
