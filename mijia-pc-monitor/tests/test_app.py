"""刷新循环里的调度逻辑。"""

import asyncio
import time
import unittest

from mijia_pc_monitor import app
from mijia_pc_monitor.config import AppConfig, from_dict
from mijia_pc_monitor.device.lcd import LCD_BUFFER_SIZE


class FakeClient:
    def __init__(self, buffer_size):
        self._buffer_size = buffer_size

    async def detect_lcd_buffer_size(self):
        return self._buffer_size


class SleepOrStopTest(unittest.IsolatedAsyncioTestCase):
    async def test_sleeps_for_the_full_interval(self):
        started = time.monotonic()
        await app._sleep_or_stop(asyncio.Event(), 0.05)
        self.assertGreaterEqual(time.monotonic() - started, 0.05)

    async def test_stop_event_wakes_early(self):
        stop = asyncio.Event()
        asyncio.get_running_loop().call_later(0.01, stop.set)
        started = time.monotonic()
        await app._sleep_or_stop(stop, 5.0)
        self.assertLess(time.monotonic() - started, 1.0)

    async def test_extra_event_wakes_early(self):
        # 断线事件也要能立刻打断等待，不然要多等一个刷新周期
        disconnected = asyncio.Event()
        asyncio.get_running_loop().call_later(0.01, disconnected.set)
        started = time.monotonic()
        await app._sleep_or_stop(asyncio.Event(), 5.0, disconnected)
        self.assertLess(time.monotonic() - started, 1.0)

    async def test_no_pending_tasks_are_left_behind(self):
        before = len(asyncio.all_tasks())
        await app._sleep_or_stop(asyncio.Event(), 0.01)
        await asyncio.sleep(0)
        self.assertLessEqual(len(asyncio.all_tasks()), before)


class ResolveModeTest(unittest.IsolatedAsyncioTestCase):
    def monitor(self, mode):
        return app.MonitorApp(from_dict({"display": {"mode": mode}}))

    async def test_auto_picks_lcd_for_lywsd03mmc(self):
        mode = await self.monitor("auto")._resolve_mode(FakeClient(LCD_BUFFER_SIZE))
        self.assertEqual(mode, "lcd")

    async def test_auto_falls_back_to_ext_for_other_models(self):
        mode = await self.monitor("auto")._resolve_mode(FakeClient(18))
        self.assertEqual(mode, "ext")

    async def test_auto_falls_back_to_ext_when_probe_fails(self):
        mode = await self.monitor("auto")._resolve_mode(FakeClient(None))
        self.assertEqual(mode, "ext")

    async def test_explicit_mode_is_respected(self):
        self.assertEqual(await self.monitor("ext")._resolve_mode(FakeClient(6)), "ext")

    async def test_forcing_lcd_on_a_mismatched_device_warns(self):
        with self.assertLogs("mijia_pc_monitor.app", level="WARNING"):
            mode = await self.monitor("lcd")._resolve_mode(FakeClient(18))
        self.assertEqual(mode, "lcd")


class FakeDisplayClient:
    """整条刷新链路的替身：记下每一帧写了什么。"""

    instances: list["FakeDisplayClient"] = []

    def __init__(self, address, adapter=None, connect_timeout=20.0):
        self.address = address
        self.connected = False
        self.disconnected_event = asyncio.Event()
        self.frames: list[bytes] = []
        self.restored = False
        FakeDisplayClient.instances.append(self)

    async def connect(self):
        self.connected = True

    async def disconnect(self):
        self.connected = False

    async def detect_lcd_buffer_size(self):
        return LCD_BUFFER_SIZE

    async def show_lcd(self, frame):
        self.frames.append(frame.to_bytes())

    async def show_ext(self, payload):
        self.frames.append(payload)

    async def restore(self):
        self.restored = True


class RefreshLoopTest(unittest.IsolatedAsyncioTestCase):
    """端到端跑一遍循环，只把蓝牙那一层换成替身。"""

    def setUp(self):
        FakeDisplayClient.instances.clear()
        self._real_client = app.MijiaDisplayClient
        app.MijiaDisplayClient = FakeDisplayClient
        self.addCleanup(setattr, app, "MijiaDisplayClient", self._real_client)

    async def run_for(self, config, seconds):
        monitor = app.MonitorApp(config)
        stop = asyncio.Event()
        asyncio.get_running_loop().call_later(seconds, stop.set)
        self.assertEqual(await monitor.run(stop), 0)
        return FakeDisplayClient.instances[0]

    async def test_pushes_frames_and_restores_on_exit(self):
        config = from_dict(
            {
                "device": {"address": "A4:C1:38:00:11:22"},
                "display": {"interval": 0.02, "dwell": 0.02, "pages": ["cpu_usage"]},
            }
        )
        client = await self.run_for(config, 0.2)
        self.assertEqual(client.address, "A4:C1:38:00:11:22")
        self.assertGreater(len(client.frames), 1)
        # auto 模式下探测到 6 字节显存，应该走 lcd 模式（帧长就是显存长度）
        self.assertTrue(all(len(frame) == LCD_BUFFER_SIZE for frame in client.frames))
        self.assertTrue(client.restored)
        self.assertFalse(client.connected)

    async def test_ext_mode_sends_ext_data_commands(self):
        config = from_dict(
            {
                "device": {"address": "AA:BB:CC:DD:EE:FF"},
                "display": {
                    "mode": "ext",
                    "interval": 0.02,
                    "dwell": 0.02,
                    "pages": ["cpu_usage"],
                },
            }
        )
        client = await self.run_for(config, 0.15)
        self.assertTrue(all(frame[0] == 0x22 for frame in client.frames))

    async def test_stops_before_connecting_when_already_asked_to_stop(self):
        config = from_dict({"device": {"address": "AA:BB:CC:DD:EE:FF"}})
        monitor = app.MonitorApp(config)
        stop = asyncio.Event()
        stop.set()
        self.assertEqual(await monitor.run(stop), 0)
        self.assertEqual(FakeDisplayClient.instances, [])


class ConstructionTest(unittest.TestCase):
    def test_invalid_pages_fail_before_connecting(self):
        config = AppConfig()
        object.__setattr__(config.display, "pages", ("nope",))
        with self.assertRaises(ValueError):
            app.MonitorApp(config)


if __name__ == "__main__":
    unittest.main()
