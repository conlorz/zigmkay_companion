# zigmkay_companion

Source-only Zigmkay editor and companion application. The repository contains
project, session, jobs, keymap, catalog, processor-runner and desktop code.
Native acceptance is not established across all intended macOS, Windows and
Linux targets.

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

## Explicit preparation

Optional desktop source acquisition is separate from normal checks:

```sh
zig build prepare-desktop-dependencies \
  -Ddesktop-acquisition=true -Ddesktop-source-cache=<absolute-cache-directory>
```

The resulting `source-inputs.zon` records verified immutable sources. Supply
its `dvui.source_path` and `ztray.source_path` to
`check-desktop-dependencies -Ddesktop-dependencies=true` using the
`desktop-dvui-source` and `desktop-ztray-source` options. This compiles and links
the native graph without launching it.

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
acquisition requires an explicit preparation-plan opt-in. Normal checks and
startup never run these operations. A prepared environment can be selected at
application launch using `--prepared-build-config <absolute-file>`.

Flash-tool preparation is also opt-in (`prepare-picotool -Dflash-tools=true`) and
requires a compatible firmware wrapper and pinned source revision. It installs
verified tools into a selected cache prefix, not onto a device. Physical
picotool acceptance and desktop flash integration remain separate gates.
