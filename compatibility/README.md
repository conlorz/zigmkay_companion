# Compatibility status

The normal dependency is the published `EuroZig/zigmkay_firmware` PR #1 head
`ba67fda557e2dffb4b86fba797ce2d2bd57fa9a4`, pinned to an immutable package
hash in `../build.zig.zon`. It supplies source for all 14 firmware selectors;
this is not a native release or an accepted stable contract. Normal builds do
not require a sibling firmware checkout. A local firmware override is an
explicit development input only.

The companion uses exactly Zig 0.17.0. The unchanged historical reference uses
Zig 0.16.0; compiler versions alone do not establish behavioral equivalence.

Offline source and compatibility checks do not establish physical hardware
acceptance. Native toolchain and platform integration, including desktop USB
identity/snapshot delivery, require validation on supported hosts. Physical
keyboard checks, startup latency and separate interrupt OUT evidence remain
hardware gates. Flashing requires an explicit hardware task. Release artifacts
and native platform acceptance are not implied by the published source pin.
