"""连接层里不依赖真实蓝牙硬件的逻辑。"""

import asyncio
import unittest

from mijia_pc_monitor.device import protocol
from mijia_pc_monitor.device.client import (
    DeviceError,
    DiscoveredDevice,
    MijiaDisplayClient,
    _adapter_kwargs,
    supports_lcd_mode,
)
from mijia_pc_monitor.device.lcd import Lcd03Frame


class FakeBleakClient:
    """够用的 BleakClient 替身：记下写进去的字节。"""

    def __init__(self, fail: bool = False):
        self.is_connected = True
        self.written: list[bytes] = []
        self.fail = fail

    async def write_gatt_char(self, _uuid, data, response=True):
        if self.fail:
            raise OSError("设备不在范围内")
        self.written.append(bytes(data))


def make_client(fail: bool = False):
    client = MijiaDisplayClient("A4:C1:38:00:11:22")
    fake = FakeBleakClient(fail=fail)
    client._client = fake
    return client, fake


class AdapterKwargsTest(unittest.TestCase):
    def test_omitted_when_not_configured(self):
        self.assertEqual(_adapter_kwargs(None), {})

    def test_uses_bluez_namespace(self):
        # bleak 3.x 起顶层 adapter= 已废弃
        self.assertEqual(_adapter_kwargs("hci1"), {"bluez": {"adapter": "hci1"}})


class LcdModeSupportTest(unittest.TestCase):
    def test_only_six_byte_buffers(self):
        self.assertTrue(supports_lcd_mode(6))
        self.assertFalse(supports_lcd_mode(18))  # 比如 MHO-C401
        self.assertFalse(supports_lcd_mode(None))


class DiscoveredDeviceTest(unittest.TestCase):
    def test_str(self):
        self.assertIn("-67 dBm", str(DiscoveredDevice("AA", "ATC_1", -67)))
        self.assertIn("(无名)", str(DiscoveredDevice("AA", None, None)))


class ScanTest(unittest.IsolatedAsyncioTestCase):
    async def test_adapter_failure_becomes_a_readable_error(self):
        # 没有蓝牙适配器时不该甩一整页 traceback 给用户
        from unittest import mock

        from mijia_pc_monitor.device import client as client_module

        fake_bleak = mock.MagicMock()
        fake_bleak.BleakScanner.discover = mock.AsyncMock(
            side_effect=FileNotFoundError(2, "No such file or directory")
        )
        with mock.patch.object(client_module, "_import_bleak", return_value=fake_bleak):
            with self.assertRaises(DeviceError) as ctx:
                await client_module.scan(timeout=0.01)
        self.assertIn("扫描失败", str(ctx.exception))


class WriteTest(unittest.IsolatedAsyncioTestCase):
    async def test_write_requires_connection(self):
        with self.assertRaises(DeviceError):
            await MijiaDisplayClient("AA").write(b"\x22")

    async def test_backend_errors_become_device_errors(self):
        client, _ = make_client(fail=True)
        with self.assertRaises(DeviceError):
            await client.write(b"\x22")

    async def test_show_lcd_writes_a_dump_command(self):
        client, fake = make_client()
        await client.show_lcd(Lcd03Frame().set_big_value(42))
        self.assertEqual(len(fake.written), 1)
        self.assertEqual(fake.written[0][0], protocol.CMD_LCD_DUMP)
        self.assertEqual(len(fake.written[0]), 7)


class RequestResponseTest(unittest.IsolatedAsyncioTestCase):
    async def test_matches_response_by_command_id(self):
        client, fake = make_client()
        task = asyncio.ensure_future(client.request(protocol.encode_lcd_query()))
        await asyncio.sleep(0)
        # 先来一条别的命令的通知，不该被误认为是应答
        client._on_notify(None, bytearray([protocol.CMD_MEASURE, 0x01]))
        self.assertFalse(task.done())
        client._on_notify(None, bytearray([protocol.CMD_LCD_DUMP, 1, 2, 3, 4, 5, 6]))
        self.assertEqual(await task, bytes([protocol.CMD_LCD_DUMP, 1, 2, 3, 4, 5, 6]))

    async def test_timeout(self):
        client, _ = make_client()
        with self.assertRaises(DeviceError):
            await client.request(protocol.encode_lcd_query(), timeout=0.01)

    async def test_disconnect_wakes_up_pending_requests(self):
        client, _ = make_client()
        task = asyncio.ensure_future(client.request(protocol.encode_lcd_query(), timeout=5))
        await asyncio.sleep(0)
        client._on_disconnect(None)
        with self.assertRaises(DeviceError):
            await task
        self.assertTrue(client.disconnected_event.is_set())

    async def test_empty_notification_is_ignored(self):
        client, _ = make_client()
        client._on_notify(None, bytearray())  # 不应抛异常


class DetectBufferSizeTest(unittest.IsolatedAsyncioTestCase):
    async def respond_with(self, client, payload):
        await asyncio.sleep(0)
        client._on_notify(None, bytearray(payload))

    async def test_reports_buffer_size(self):
        client, _ = make_client()
        task = asyncio.ensure_future(client.detect_lcd_buffer_size())
        await self.respond_with(client, [protocol.CMD_LCD_DUMP] + [0] * 6)
        self.assertEqual(await task, 6)

    async def test_no_answer_means_unknown(self):
        client, fake = make_client(fail=True)
        self.assertIsNone(await client.detect_lcd_buffer_size())


class RestoreTest(unittest.IsolatedAsyncioTestCase):
    async def test_releases_the_display_it_took_over(self):
        client, fake = make_client()
        await client.show_lcd(Lcd03Frame())
        fake.written.clear()
        await client.restore()
        self.assertEqual(fake.written[0], protocol.encode_lcd_release())
        self.assertEqual(fake.written[1], protocol.encode_ext_data_release())

    async def test_does_not_release_lcd_it_never_took(self):
        client, fake = make_client()
        await client.restore()
        self.assertEqual(fake.written, [protocol.encode_ext_data_release()])

    async def test_failure_to_restore_is_not_fatal(self):
        # 设备已经走远/没电时，恢复默认显示失败不该影响退出
        client, _ = make_client(fail=True)
        await client.restore()


if __name__ == "__main__":
    unittest.main()
