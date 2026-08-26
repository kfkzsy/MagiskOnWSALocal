"""指标采集里可以脱离硬件测试的部分。"""

import tempfile
import unittest
from pathlib import Path
from unittest import mock

from mijia_pc_monitor.metrics.collector import MetricsCollector
from mijia_pc_monitor.metrics.gpu import _parse_nvidia_smi
from mijia_pc_monitor.metrics.sysfs import EnergyCounter, read_int
from mijia_pc_monitor.metrics.types import Reading, Snapshot
from mijia_pc_monitor.rounding import round_half_up


class RoundingTest(unittest.TestCase):
    def test_half_goes_away_from_zero(self):
        # 内置 round() 会给出 72，屏幕上看着像少了 1 度
        self.assertEqual(round_half_up(72.5), 73)
        self.assertEqual(round_half_up(73.5), 74)
        self.assertEqual(round_half_up(-2.5), -3)

    def test_ordinary_cases(self):
        self.assertEqual(round_half_up(0.4), 0)
        self.assertEqual(round_half_up(0.6), 1)
        self.assertEqual(round_half_up(-0.4), 0)


class EnergyCounterTest(unittest.TestCase):
    """RAPL 只给累计能量，功率要靠两次读数的差值算出来。"""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.energy = Path(self._tmp.name) / "energy_uj"
        self.max_range = Path(self._tmp.name) / "max_energy_range_uj"
        self.max_range.write_text("1000000000")

    def counter(self):
        return EnergyCounter(self.energy, self.max_range)

    def test_first_read_has_no_baseline(self):
        self.energy.write_text("1000000")
        with mock.patch("time.monotonic", return_value=100.0):
            self.assertIsNone(self.counter().watts())

    def test_watts_from_delta(self):
        counter = self.counter()
        self.energy.write_text("1000000")
        with mock.patch("time.monotonic", return_value=100.0):
            counter.watts()
        # 2 秒内多耗了 30 焦耳 → 15 W
        self.energy.write_text(str(1000000 + 30_000_000))
        with mock.patch("time.monotonic", return_value=102.0):
            self.assertAlmostEqual(counter.watts(), 15.0)

    def test_counter_wraparound(self):
        counter = self.counter()
        self.energy.write_text("999000000")
        with mock.patch("time.monotonic", return_value=100.0):
            counter.watts()
        self.energy.write_text("1000000")  # 绕回去了
        with mock.patch("time.monotonic", return_value=101.0):
            self.assertAlmostEqual(counter.watts(), 2.0)

    def test_wraparound_without_range_is_dropped(self):
        counter = EnergyCounter(self.energy, None)
        self.energy.write_text("999000000")
        with mock.patch("time.monotonic", return_value=100.0):
            counter.watts()
        self.energy.write_text("1000000")
        with mock.patch("time.monotonic", return_value=101.0):
            self.assertIsNone(counter.watts())

    def test_unreadable_counter(self):
        self.assertIsNone(EnergyCounter(Path("/nonexistent/energy_uj")).watts())

    def test_zero_elapsed_time(self):
        counter = self.counter()
        self.energy.write_text("1000000")
        with mock.patch("time.monotonic", return_value=100.0):
            counter.watts()
            self.assertIsNone(counter.watts())


class SysfsTest(unittest.TestCase):
    def test_read_int_handles_garbage(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "value"
            path.write_text("not a number")
            self.assertIsNone(read_int(path))
            path.write_text(" 42 \n")
            self.assertEqual(read_int(path), 42)

    def test_read_int_handles_missing_file(self):
        self.assertIsNone(read_int(Path("/nonexistent/value")))


class NvidiaSmiParseTest(unittest.TestCase):
    def test_normal_output(self):
        reading = _parse_nvidia_smi("42, 115.32, 61, NVIDIA GeForce RTX 4070\n")
        self.assertEqual(reading.usage, 42.0)
        self.assertEqual(reading.power_w, 115.32)
        self.assertEqual(reading.temp_c, 61.0)
        self.assertEqual(reading.name, "NVIDIA GeForce RTX 4070")

    def test_unsupported_fields_become_none(self):
        # 笔记本上的部分型号读不到功耗，nvidia-smi 会写 [N/A]
        reading = _parse_nvidia_smi("7, [N/A], 45, Quadro T1000")
        self.assertEqual(reading.usage, 7.0)
        self.assertIsNone(reading.power_w)
        self.assertEqual(reading.temp_c, 45.0)

    def test_multi_gpu_takes_the_first(self):
        reading = _parse_nvidia_smi("10, 50, 40, A\n90, 300, 80, B\n")
        self.assertEqual(reading.usage, 10.0)

    def test_empty_output(self):
        self.assertEqual(_parse_nvidia_smi(""), Reading())
        self.assertEqual(_parse_nvidia_smi("\n"), Reading())

    def test_truncated_output(self):
        self.assertEqual(_parse_nvidia_smi("55").usage, 55.0)


class SnapshotTest(unittest.TestCase):
    def test_as_dict(self):
        snapshot = Snapshot(cpu=Reading(usage=1.0), gpu=Reading(temp_c=2.0))
        data = snapshot.as_dict()
        self.assertEqual(data["cpu"]["usage"], 1.0)
        self.assertEqual(data["gpu"]["temp_c"], 2.0)
        self.assertIn("timestamp", data)

    def test_defaults_are_all_none(self):
        self.assertEqual(Reading(), Reading(None, None, None, None))


class CollectorSafetyTest(unittest.TestCase):
    def test_a_failing_source_does_not_break_the_loop(self):
        def boom():
            raise RuntimeError("驱动挂了")

        with self.assertLogs("mijia_pc_monitor.metrics.collector", level="WARNING"):
            self.assertEqual(MetricsCollector._safe(boom), Reading())


if __name__ == "__main__":
    unittest.main()
