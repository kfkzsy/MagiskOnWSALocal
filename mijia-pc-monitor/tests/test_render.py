"""页面编排与两种显示模式的测试。"""

import unittest

from mijia_pc_monitor.device import lcd, protocol
from mijia_pc_monitor.metrics.types import Reading, Snapshot
from mijia_pc_monitor.render import (
    DEFAULT_PAGES,
    PAGES,
    LOAD_HIGH,
    LOAD_MEDIUM,
    PageRotator,
    format_page,
    render_ext,
    render_lcd,
    resolve_pages,
    smiley_for_load,
)

FULL = Snapshot(
    cpu=Reading(usage=43.0, power_w=88.0, temp_c=72.5, name="CPU"),
    gpu=Reading(usage=97.0, power_w=241.0, temp_c=68.0, name="GPU"),
)
NO_GPU = Snapshot(cpu=FULL.cpu, gpu=Reading())
EMPTY = Snapshot(cpu=Reading(), gpu=Reading())


class PageRegistryTest(unittest.TestCase):
    def test_default_pages_cover_all_six_metrics(self):
        self.assertEqual(len(DEFAULT_PAGES), 6)
        covered = {(PAGES[k].primary.component, PAGES[k].primary.field) for k in DEFAULT_PAGES}
        self.assertEqual(
            covered,
            {
                ("cpu", "usage"),
                ("cpu", "power_w"),
                ("cpu", "temp_c"),
                ("gpu", "usage"),
                ("gpu", "power_w"),
                ("gpu", "temp_c"),
            },
        )

    def test_labels_are_two_chars_and_unique(self):
        labels = [page.label for page in PAGES.values()]
        self.assertEqual(len(set(labels)), len(labels))
        for label in labels:
            self.assertEqual(len(label), 2)
            for char in label:
                self.assertNotEqual(lcd.glyph(char), 0x00, f"标签 {label!r} 画不出来")

    def test_resolve_rejects_unknown_page(self):
        with self.assertRaises(ValueError) as ctx:
            resolve_pages(["cpu_usage", "cpu_fan"])
        self.assertIn("cpu_fan", str(ctx.exception))

    def test_resolve_rejects_empty(self):
        with self.assertRaises(ValueError):
            resolve_pages([])

    def test_temperature_pages_use_one_decimal(self):
        for key in ("cpu_temp", "gpu_temp"):
            self.assertEqual(PAGES[key].decimals, 1)
        for key in ("cpu_usage", "cpu_power"):
            self.assertEqual(PAGES[key].decimals, 0)


class SmileyTest(unittest.TestCase):
    def test_thresholds(self):
        self.assertEqual(smiley_for_load(10), protocol.SMILEY_HAPPY)
        self.assertEqual(smiley_for_load(LOAD_MEDIUM), protocol.SMILEY_RING)
        self.assertEqual(smiley_for_load(LOAD_HIGH), protocol.SMILEY_ANGRY)
        self.assertEqual(smiley_for_load(None), protocol.SMILEY_OFF)


class RenderLcdTest(unittest.TestCase):
    def test_value_and_label(self):
        frame = render_lcd(PAGES["gpu_power"], FULL)
        self.assertEqual(frame.data[lcd.IDX_BIG_HUNDREDS], lcd.FONT["2"])
        self.assertEqual(frame.data[lcd.IDX_BIG_TENS], lcd.FONT["4"])
        self.assertEqual(frame.data[lcd.IDX_BIG_ONES], lcd.FONT["1"])
        self.assertEqual(frame.data[lcd.IDX_SMALL_TENS], lcd.FONT["G"])
        self.assertEqual(frame.data[lcd.IDX_SMALL_ONES], lcd.FONT["P"])

    def test_temperature_page_lights_celsius(self):
        frame = render_lcd(PAGES["cpu_temp"], FULL)
        self.assertEqual(
            (frame.data[lcd.IDX_SYMBOLS] & lcd.MASK_TEMP_SYMBOL) >> 5,
            protocol.TEMP_SYMBOL_C,
        )
        self.assertTrue(frame.data[lcd.IDX_BIG_TENS] & lcd.BIT_POINT)

    def test_usage_page_lights_percent(self):
        self.assertTrue(
            render_lcd(PAGES["cpu_usage"], FULL).data[lcd.IDX_SMALL_ONES] & lcd.BIT_PERCENT
        )
        self.assertFalse(
            render_lcd(PAGES["cpu_power"], FULL).data[lcd.IDX_SMALL_ONES] & lcd.BIT_PERCENT
        )

    def test_smiley_follows_the_shown_component(self):
        # GPU 97% 应该是"生气"，即便同一时刻 CPU 只有 43%
        self.assertEqual(
            render_lcd(PAGES["gpu_temp"], FULL).data[lcd.IDX_SYMBOLS] & lcd.MASK_SMILEY,
            protocol.SMILEY_ANGRY,
        )
        self.assertEqual(
            render_lcd(PAGES["cpu_temp"], FULL).data[lcd.IDX_SYMBOLS] & lcd.MASK_SMILEY,
            protocol.SMILEY_HAPPY,
        )

    def test_ble_icon_is_optional(self):
        self.assertTrue(render_lcd(PAGES["cpu_temp"], FULL, ble=True).data[lcd.IDX_SYMBOLS] & lcd.BIT_BLE)
        self.assertFalse(render_lcd(PAGES["cpu_temp"], FULL, ble=False).data[lcd.IDX_SYMBOLS] & lcd.BIT_BLE)

    def test_missing_metric_shows_dashes(self):
        frame = render_lcd(PAGES["gpu_temp"], NO_GPU)
        self.assertEqual(frame.data[lcd.IDX_BIG_ONES], lcd.SEG_G)


class RenderExtTest(unittest.TestCase):
    def decode(self, payload):
        self.assertEqual(payload[0], protocol.CMD_EXT_DATA)
        return protocol.decode_ext_data(payload[1:])

    def test_primary_goes_to_big_number(self):
        data = self.decode(render_ext(PAGES["cpu_temp"], FULL, hold_seconds=8))
        self.assertEqual(data["big_number_x10"], 725)
        self.assertEqual(data["small_number"], 43)  # 辅助指标是占用率
        self.assertEqual(data["vtime_sec"], 8)
        self.assertEqual(data["temp_symbol"], protocol.TEMP_SYMBOL_C)
        self.assertTrue(data["percent"])

    def test_power_page_has_no_temp_symbol(self):
        data = self.decode(render_ext(PAGES["gpu_power"], FULL, hold_seconds=8))
        self.assertEqual(data["big_number_x10"], 2410)
        self.assertEqual(data["temp_symbol"], protocol.TEMP_SYMBOL_NONE)

    def test_usage_page_secondary_is_temperature(self):
        data = self.decode(render_ext(PAGES["cpu_usage"], FULL, hold_seconds=8))
        self.assertEqual(data["big_number_x10"], 430)
        self.assertEqual(data["small_number"], 73)  # 72.5°C 取整
        self.assertFalse(data["percent"])  # 小号区放的是温度，不该点亮 %

    def test_missing_secondary_does_not_light_percent(self):
        data = self.decode(render_ext(PAGES["gpu_power"], NO_GPU, hold_seconds=8))
        self.assertFalse(data["percent"])


class PageRotatorTest(unittest.TestCase):
    def rotator(self, keys, dwell=4.0):
        return PageRotator(resolve_pages(keys), dwell)

    def test_stays_on_a_page_for_the_dwell_time(self):
        rotator = self.rotator(["cpu_usage", "cpu_temp"], dwell=4.0)
        self.assertEqual(rotator.current(FULL, 0.0).key, "cpu_usage")
        self.assertEqual(rotator.current(FULL, 3.9).key, "cpu_usage")
        self.assertEqual(rotator.current(FULL, 4.0).key, "cpu_temp")
        self.assertEqual(rotator.current(FULL, 8.0).key, "cpu_usage")

    def test_skips_pages_without_data(self):
        rotator = self.rotator(["cpu_usage", "gpu_usage", "cpu_temp"], dwell=1.0)
        seen = [rotator.current(NO_GPU, t).key for t in (0.0, 1.0, 2.0, 3.0)]
        self.assertNotIn("gpu_usage", seen)
        self.assertEqual(seen, ["cpu_usage", "cpu_temp", "cpu_usage", "cpu_temp"])

    def test_switches_immediately_when_current_page_loses_data(self):
        rotator = self.rotator(["gpu_temp", "cpu_temp"], dwell=10.0)
        self.assertEqual(rotator.current(FULL, 0.0).key, "gpu_temp")
        self.assertEqual(rotator.current(NO_GPU, 1.0).key, "cpu_temp")

    def test_returns_none_when_nothing_is_available(self):
        self.assertIsNone(self.rotator(DEFAULT_PAGES).current(EMPTY, 0.0))

    def test_single_available_page_does_not_flip(self):
        rotator = self.rotator(["cpu_temp", "gpu_temp"], dwell=1.0)
        keys = {rotator.current(NO_GPU, t).key for t in (0.0, 1.0, 2.0, 3.0)}
        self.assertEqual(keys, {"cpu_temp"})

    def test_requires_at_least_one_page(self):
        with self.assertRaises(ValueError):
            PageRotator([], 1.0)


class FormatPageTest(unittest.TestCase):
    def test_units(self):
        self.assertEqual(format_page(PAGES["cpu_usage"], FULL), "CPU 占用率: 43%")
        self.assertEqual(format_page(PAGES["gpu_power"], FULL), "GPU 功耗: 241 W")
        self.assertEqual(format_page(PAGES["cpu_temp"], FULL), "CPU 温度: 72.5 °C")

    def test_missing_value(self):
        self.assertEqual(format_page(PAGES["gpu_temp"], NO_GPU), "GPU 温度: -- °C")


if __name__ == "__main__":
    unittest.main()
