"""配置读取与命令行覆盖的测试。"""

import os
import tempfile
import unittest
from pathlib import Path

from mijia_pc_monitor.config import (
    ENV_CONFIG_PATH,
    MODE_EXT,
    AppConfig,
    apply_overrides,
    from_dict,
    load_config,
)


class DefaultsTest(unittest.TestCase):
    def test_defaults_are_valid(self):
        config = AppConfig().validate()
        self.assertEqual(config.display.mode, "auto")
        self.assertEqual(len(config.display.pages), 6)

    def test_hold_seconds_outlives_the_refresh_interval(self):
        # 有效期必须明显长于刷新周期，否则两次刷新之间屏幕会闪回温湿度
        config = AppConfig()
        self.assertGreater(config.display.hold_seconds(), config.display.interval)

    def test_hold_seconds_has_a_floor(self):
        config = from_dict({"display": {"interval": 0.5}})
        self.assertGreaterEqual(config.display.hold_seconds(), 5)


class FromDictTest(unittest.TestCase):
    def test_partial_config_keeps_defaults(self):
        config = from_dict({"device": {"address": "A4:C1:38:00:11:22"}})
        self.assertEqual(config.device.address, "A4:C1:38:00:11:22")
        self.assertEqual(config.device.name_prefix, "ATC_")

    def test_mode_is_case_insensitive(self):
        self.assertEqual(from_dict({"display": {"mode": "EXT"}}).display.mode, MODE_EXT)

    def test_invalid_mode(self):
        with self.assertRaises(ValueError):
            from_dict({"display": {"mode": "oled"}})

    def test_invalid_page(self):
        with self.assertRaises(ValueError):
            from_dict({"display": {"pages": ["cpu_usage", "ram_usage"]}})

    def test_non_positive_interval(self):
        with self.assertRaises(ValueError):
            from_dict({"display": {"interval": 0}})
        with self.assertRaises(ValueError):
            from_dict({"display": {"dwell": -1}})


class OverrideTest(unittest.TestCase):
    def test_cli_wins_over_file(self):
        config = from_dict({"device": {"address": "AA:AA:AA:AA:AA:AA"}})
        updated = apply_overrides(config, address="BB:BB:BB:BB:BB:BB")
        self.assertEqual(updated.device.address, "BB:BB:BB:BB:BB:BB")

    def test_none_means_not_given(self):
        config = from_dict({"device": {"address": "AA:AA:AA:AA:AA:AA"}})
        self.assertEqual(apply_overrides(config, address=None).device.address, "AA:AA:AA:AA:AA:AA")

    def test_pages_override(self):
        updated = apply_overrides(AppConfig(), pages=["gpu_temp", "gpu_power"])
        self.assertEqual(updated.display.pages, ("gpu_temp", "gpu_power"))

    def test_bad_override_is_rejected(self):
        with self.assertRaises(ValueError):
            apply_overrides(AppConfig(), pages=["nope"])

    def test_log_level_is_upper_cased(self):
        self.assertEqual(apply_overrides(AppConfig(), log_level="debug").log_level, "DEBUG")

    def test_original_config_is_not_mutated(self):
        config = AppConfig()
        apply_overrides(config, address="AA:AA:AA:AA:AA:AA", interval=9.0)
        self.assertIsNone(config.device.address)
        self.assertEqual(config.display.interval, 2.0)


class LoadFileTest(unittest.TestCase):
    def write(self, directory, text):
        path = Path(directory) / "config.toml"
        path.write_text(text, encoding="utf-8")
        return path

    def test_load_from_explicit_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self.write(
                tmp,
                '[device]\naddress = "A4:C1:38:AA:BB:CC"\n'
                '[display]\nmode = "lcd"\ninterval = 3\npages = ["cpu_temp"]\n'
                '[logging]\nlevel = "debug"\n',
            )
            config = load_config(path)
        self.assertEqual(config.device.address, "A4:C1:38:AA:BB:CC")
        self.assertEqual(config.display.mode, "lcd")
        self.assertEqual(config.display.interval, 3.0)
        self.assertEqual(config.display.pages, ("cpu_temp",))
        self.assertEqual(config.log_level, "DEBUG")

    def test_missing_explicit_path_is_an_error(self):
        with self.assertRaises(FileNotFoundError):
            load_config("/nonexistent/mijia.toml")

    def test_env_var_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self.write(tmp, '[display]\ninterval = 7\n')
            os.environ[ENV_CONFIG_PATH] = str(path)
            try:
                self.assertEqual(load_config().display.interval, 7.0)
            finally:
                del os.environ[ENV_CONFIG_PATH]

    def test_broken_env_var_path(self):
        os.environ[ENV_CONFIG_PATH] = "/nonexistent/mijia.toml"
        try:
            with self.assertRaises(FileNotFoundError):
                load_config()
        finally:
            del os.environ[ENV_CONFIG_PATH]


if __name__ == "__main__":
    unittest.main()
