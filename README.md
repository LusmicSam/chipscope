# chipscope

A native macOS app that shows a live, clickable map of an Apple Silicon Mac, from the whole machine down to a single CPU core. Built and tested on an M1 Pro MacBook Pro 14" (MacBookPro18,3). No sudo, no browser, no Python: SwiftUI plus a small C layer and one native probe helper. It costs about 4% of one CPU core while it is on screen and almost nothing when hidden.

```bash
./app/run.sh          # build, install to ~/Applications/chipscope.app, launch
```

It builds with the Xcode Command Line Tools (SwiftPM + clang); full Xcode is not needed.

The first version was a browser UI with a Python collector (`chipscope/`, `web/`, `./start.sh`). It still works, but the native app replaces it.

## What you see

- **Map**: Mac → M1 Pro → CPU cluster → core, plus GPU and unified memory views.
  - Blocks go from slate to red with real load: busy %, busy × clock, or power.
  - Memory traffic is animated along the real path, agent → fabric → system cache → memory controllers → DRAM. Read and write are separate lanes.
  - Fused-off cores (2 P-cores, 2 GPU cores on this chip) are shown hatched.
- **Heat paths**: heats one block (P-cores, GPU, SSD, Neural Engine) for 45 s and times when each of the ~250 temperature sensors warms up. The arrival order is the measured heat path, from the die through the spreader and heat pipe to the far side of the board.
- **Optimize**: finds orphaned dev processes (parent gone, still running), runaway CPU, memory hogs grouped by app, and memory pressure. It offers a fix and always asks before stopping anything.
- **Ports & power**: what is plugged into each port (identified over USB Power Delivery), which way power flows, and the charger's offers and active contract.
- **Signal timing**: a probe suite (~30 s) places each component by how long a signal takes to reach it:
  - caches and DRAM, measured by pointer-chasing;
  - core-to-core, measured by cache-line ping-pong (the two P-clusters show up on their own);
  - SSD, GPU, Neural Engine, kernel, SMC and HID sensors, and Wi-Fi.
- **Sensors**: every SMC key, the named HID temperature sensors and the IOReport counter groups, each with its read time.
- **Load buttons** start a 20 s load on the P-cores, E-cores, memory, GPU, Neural Engine or SSD, so you can watch each block light up.
- **Timeline**: click or drag it to replay the last 5 minutes.
- **Explain**: switches each tooltip to say what the block is and which counter the number comes from.

## Where the numbers come from

| Source | Used for |
|---|---|
| IOReport (private, no sudo) | CPU/GPU state residency, the energy model, and memory-controller traffic per agent |
| IOKit | GPU utilisation, battery telemetry, SSD driver statistics |
| AppleSMC user client | fans, temperatures, power keys |
| HID event system | named temperature sensors |
| Device tree, pmgr, sysctl | topology, frequency tables, cache sizes |
| `vm_stat`, `ps`, `netstat` | memory, processes, network |

Facts macOS does not expose come from Apple's published specs: SLC size, memory bus, die core counts, ports. Each one is labelled as such in the UI.

## Tests

```bash
cd app && swift build -c release --product ChipCheck && .build/release/ChipCheck   # unit checks + live smoke test
.build/release/ChipCheck --collect 20                                               # collector CPU cost
CHIPSCOPE_SNAPSHOT_DIR=/tmp/shots ~/Applications/chipscope.app/Contents/MacOS/ChipScope   # PNG of every page
```

The browser version keeps its own tests (`tests/test_core.py`, `tests/verify_loads.py`, `tests/live_check.mjs`).
