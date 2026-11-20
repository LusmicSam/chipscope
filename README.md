# chipscope

A live, clickable map of an Apple Silicon Mac, from the whole machine down to a single CPU core. Built and tested on an M1 Pro MacBook Pro 14" (MacBookPro18,3). It needs no sudo and installs nothing.

```bash
./start.sh            # serves http://127.0.0.1:7878 and opens it
```

The first start compiles a small native helper with `clang`, so the Xcode Command Line Tools must be installed.

## What you see

- **Map**: Mac → M1 Pro → CPU cluster → core, plus GPU and unified memory views.
  - Blocks go from slate to red with real load: busy %, busy × clock, or power.
  - Memory traffic is animated along the real path, agent → fabric → system cache → memory controllers → DRAM. Read and write are separate lanes.
  - Fused-off cores (2 P-cores, 2 GPU cores on this chip) are shown hatched.
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
/usr/bin/python3 -m unittest tests.test_core     # unit
/usr/bin/python3 tests/verify_loads.py           # live: each load raises its block's counter
node tests/live_check.mjs                        # live: every view updates, no JS errors
tests/shots.sh                                   # screenshots of every view
```
