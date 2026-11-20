"""Unit tests for the parts that turn raw counters into numbers. Run: /usr/bin/python3 -m unittest -v"""
import struct
import unittest

from chipscope import native, sampler, smc, system
from chipscope.ioreport import residency_summary

E_FREQS = [600, 972, 1332, 1704, 2064]
G_FREQS = [0, 388, 486, 648, 777, 972, 1296]


class Residency(unittest.TestCase):
    def test_cpu_busy_and_clock(self):
        st = [("IDLE", 50), ("V0P4", 25), ("V1P3", 0), ("V2P2", 0), ("V3P1", 0), ("V4P0", 25)]
        busy, mhz, _ = residency_summary(st, E_FREQS)
        self.assertAlmostEqual(busy, 0.5)
        self.assertAlmostEqual(mhz, (600 + 2064) / 2)

    def test_gpu_full_load_in_p6_is_max_clock(self):
        # Measured on this Mac: a 100% GPU load sits entirely in P6 -> 1296 MHz.
        st = [("OFF", 0)] + [(f"P{i}", 100 if i == 6 else 0) for i in range(1, 16)]
        busy, mhz, _ = residency_summary(st, G_FREQS)
        self.assertEqual(busy, 1.0)
        self.assertEqual(mhz, 1296)

    def test_gpu_low_states_map_from_the_bottom(self):
        st = [("OFF", 50), ("P1", 50)] + [(f"P{i}", 0) for i in range(2, 16)]
        self.assertEqual(residency_summary(st, G_FREQS)[1], 388)

    def test_ambiguous_mapping_reports_no_clock(self):
        st = [("OFF", 0)] + [(f"P{i}", 10) for i in range(1, 16)]
        self.assertIsNone(residency_summary(st, G_FREQS)[1])

    def test_all_idle(self):
        self.assertEqual(residency_summary([("IDLE", 10)], E_FREQS)[:2], (0.0, None))


TOPO = {
    "clusters": [{"id": "eclu", "type": "E", "ioreport": "ECPU", "energy": "EACC", "amc": "ECPU", "freqs": E_FREQS,
                  "cores": [{"id": "eclu.0", "ioreport": "ECPU000", "energy": "EACC_CPU0", "fused": False},
                            {"id": "eclu.1", "fused": True}]}],
    "gpu": {"freqs": G_FREQS},
}


def raw(**kw):
    r = {"dt": 1.0, "amc": {}, "energy": {}, "core_states": {}, "cluster_states": {}, "gpu_states": [], "pcie": {}}
    r.update(kw)
    return r


class ChipFrame(unittest.TestCase):
    def test_fused_core_skipped_and_power_read(self):
        f = sampler.build_chip_frame(TOPO, raw(energy={"EACC_CPU0": 0.25},
                                               core_states={"ECPU000": [("IDLE", 1), ("V4P0", 1)]}), {})
        self.assertEqual(list(f["cores"]), ["eclu.0"])
        self.assertEqual(f["cores"]["eclu.0"]["w"], 0.25)
        self.assertEqual(f["cores"]["eclu.0"]["busy"], 0.5)

    def test_slc_hit_is_derived_from_dram_vs_agents(self):
        amc = {"ECPU RD": 300e6, "ECPU WR": 100e6, "DCS RD": 60e6, "DCS WR": 40e6}
        f = sampler.build_chip_frame(TOPO, raw(amc=amc), {})
        self.assertAlmostEqual(f["mem"]["slc_hit"], 0.75)

    def test_slc_hit_hidden_under_noise_floor(self):
        f = sampler.build_chip_frame(TOPO, raw(amc={"ECPU RD": 1e6, "DCS RD": 1e6}), {})
        self.assertIsNone(f["mem"]["slc_hit"])

    def test_fabric_member_sum(self):
        amc = {"PCPU0 RD": 10, "PCPU0 WR": 5, "ECPU RD": 1, "ECPU WR": 1, "AFC RD": 12, "AFC WR": 6}
        f = sampler.build_chip_frame(TOPO, raw(amc=amc), {})
        self.assertEqual(f["fabric"]["AFC"], [12, 6, 17])


class SMCDecode(unittest.TestCase):
    def test_types(self):
        self.assertAlmostEqual(smc.decode("flt ", struct.pack("<f", 42.5)), 42.5)
        self.assertEqual(smc.decode("ui16", b"\x01\x02"), 258)
        self.assertEqual(smc.decode("sp78", b"\x20\x80"), 32.5)
        self.assertEqual(smc.decode("fpe2", b"\x00\x10"), 4.0)
        self.assertIsNone(smc.decode("ch8*", b"abc"))

    def test_fourcc_roundtrip(self):
        self.assertEqual(smc.unfourcc(smc.fourcc("Tp09")), "Tp09")


class Parsers(unittest.TestCase):
    def test_vm_stat(self):
        txt = ("Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free: 10.\nPages wired down: 2.\n"
               '"Anonymous pages": 5.\nPages purgeable: 1.\nPages occupied by compressor: 3.\n')
        v = system.parse_vm_stat(txt)
        self.assertEqual(v["free"], 10 * 16384)
        self.assertEqual(v["anonymous"], 5 * 16384)
        self.assertEqual(v["compressed"], 3 * 16384)

    def test_netstat_link_rows(self):
        txt = ("Name  Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll\n"
               "en0   1500  <Link#11>   aa:bb:cc:dd:ee:ff  100     0        5000      50     0       700     0\n"
               "en0   1500  192.168.1     192.168.1.5      100     -        5000      50     -       700     -\n"
               "utun0 1380  <Link#20>                       1     0          10       2     0         20     0\n")
        self.assertEqual(system.parse_netstat(txt), {"en0": (5000, 700), "utun0": (10, 20)})

    def test_ps(self):
        rows = system.parse_ps("  1  0.5  100 /sbin/launchd\n 42 75.0 2048 /Applications/X.app/Contents/MacOS/X\n")
        self.assertEqual(rows[0][:3], [42, "X", 75.0])
        self.assertEqual(rows[0][3], 2048 * 1024)

    def test_disk_rates(self):
        a = dict(rd_bytes=0, wr_bytes=0, rd_ops=0, wr_ops=0, rd_ns=0, wr_ns=0)
        b = dict(rd_bytes=1000, wr_bytes=0, rd_ops=10, wr_ops=0, rd_ns=10 * 90_000, wr_ns=0)
        r = system.disk_rates(a, b, 1.0)
        self.assertEqual(r["rd_bps"], 1000)
        self.assertAlmostEqual(r["rd_lat_us"], 90.0)
        self.assertIsNone(r["wr_lat_us"])


ATOPO = {"caches": dict(p_l1d=128 << 10, p_l2=12 << 20, e_l1d=64 << 10, e_l2=4 << 20),
         "spec": {"slc_bytes": 24 << 20},
         "clusters": [{"id": "eclu", "type": "E", "cores": [{"logical": 0, "fused": False}, {"logical": 1, "fused": False}]},
                      {"id": "pclu0", "type": "P", "cores": [{"logical": 2, "fused": False}, {"logical": 3, "fused": False}]},
                      {"id": "pclu1", "type": "P", "cores": [{"logical": 5, "fused": False}]}]}


class Atlas(unittest.TestCase):
    def test_c2c_classes(self):
        pairs = [[2, 3, 40.0], [3, 2, 42.0], [2, 5, 160.0], [0, 2, 200.0], [0, 1, 90.0], [9, 2, 1.0]]
        c = native.c2c_classes(ATOPO, pairs)
        self.assertEqual(c["same_p"]["n"], 2)
        self.assertEqual(c["cross_p"]["p50"], 160.0)
        self.assertEqual(c["p_e"]["p50"], 200.0)
        self.assertEqual(c["same_e"]["p50"], 90.0)

    def test_memlat_bands_follow_cache_sizes(self):
        pts = [[32 << 10, 1.0, 2], [1 << 20, 5.5, 2], [16 << 20, 60.0, 2], [256 << 20, 125.0, 2]]
        a = native.atlas(ATOPO, {"memlat_p": pts}, {})
        got = {e["id"]: e["ns"] for e in a["entries"]}
        self.assertEqual((got["p_l1"], got["p_l2"], got["slc"], got["dram"]), (1.0, 5.5, 60.0, 125.0))
        self.assertEqual([e["id"] for e in a["entries"]], ["p_l1", "p_l2", "slc", "dram"])  # sorted by time


if __name__ == "__main__":
    unittest.main()
