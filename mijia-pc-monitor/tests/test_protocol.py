"""协议编码的测试。golden 值按固件的结构体定义手算得出。"""

import unittest

from mijia_pc_monitor.device import protocol


class EncodeExtDataTest(unittest.TestCase):
    def test_layout_matches_firmware_struct(self):
        # big=45.6°C, small=78, 30 秒有效期, 笑脸=happy, 点亮 % 和 °C
        payload = protocol.encode_ext_data(
            456,
            78,
            30,
            smiley=protocol.SMILEY_HAPPY,
            percent=True,
            temp_symbol=protocol.TEMP_SYMBOL_C,
        )
        self.assertEqual(payload[0], protocol.CMD_EXT_DATA)
        self.assertEqual(len(payload), 8)  # 1 命令号 + 7 字节 external_data_t
        self.assertEqual(payload.hex(), "22c8014e001e00ad")

    def test_flag_bits(self):
        flags = protocol.encode_ext_data(0, 0, 0, smiley=7)[-1]
        self.assertEqual(flags, 0x07)
        self.assertEqual(protocol.encode_ext_data(0, 0, 0, percent=True)[-1], 0x08)
        self.assertEqual(protocol.encode_ext_data(0, 0, 0, battery=True)[-1], 0x10)
        self.assertEqual(protocol.encode_ext_data(0, 0, 0, temp_symbol=5)[-1], 0xA0)

    def test_negative_big_number(self):
        payload = protocol.encode_ext_data(-105, -5, 60)
        decoded = protocol.decode_ext_data(payload[1:])
        self.assertEqual(decoded["big_number_x10"], -105)
        self.assertEqual(decoded["small_number"], -5)

    def test_values_are_clamped_not_rejected(self):
        # 读数异常时宁可显示到边界，也不要抛异常打断刷新循环
        decoded = protocol.decode_ext_data(protocol.encode_ext_data(999999, 5000, 10)[1:])
        self.assertEqual(decoded["big_number_x10"], protocol.BIG_NUMBER_MAX)
        self.assertEqual(decoded["small_number"], protocol.SMALL_NUMBER_MAX)

        decoded = protocol.decode_ext_data(protocol.encode_ext_data(-99999, -500, 10)[1:])
        self.assertEqual(decoded["big_number_x10"], protocol.BIG_NUMBER_MIN)
        self.assertEqual(decoded["small_number"], protocol.SMALL_NUMBER_MIN)

    def test_vtime_forever(self):
        decoded = protocol.decode_ext_data(
            protocol.encode_ext_data(0, 0, protocol.VTIME_FOREVER)[1:]
        )
        self.assertEqual(decoded["vtime_sec"], 0xFFFF)

    def test_roundtrip(self):
        payload = protocol.encode_ext_data(
            -95, 42, 120, smiley=3, percent=True, battery=True, temp_symbol=7
        )
        self.assertEqual(
            protocol.decode_ext_data(payload[1:]),
            {
                "big_number_x10": -95,
                "small_number": 42,
                "vtime_sec": 120,
                "smiley": 3,
                "percent": True,
                "battery": True,
                "temp_symbol": 7,
            },
        )

    def test_release_expires_immediately(self):
        decoded = protocol.decode_ext_data(protocol.encode_ext_data_release()[1:])
        self.assertEqual(decoded["vtime_sec"], 0)

    def test_decode_rejects_short_payload(self):
        with self.assertRaises(ValueError):
            protocol.decode_ext_data(b"\x00\x01\x02")


class LcdDumpTest(unittest.TestCase):
    def test_dump_prefixes_command(self):
        payload = protocol.encode_lcd_dump(bytes([1, 2, 3, 4, 5, 6]))
        self.assertEqual(payload, bytes([protocol.CMD_LCD_DUMP, 1, 2, 3, 4, 5, 6]))

    def test_empty_dump_is_rejected(self):
        # 空负载在固件里是"释放显存"，不能和写显存混为一谈
        with self.assertRaises(ValueError):
            protocol.encode_lcd_dump(b"")

    def test_release_is_command_only(self):
        self.assertEqual(protocol.encode_lcd_release(), bytes([protocol.CMD_LCD_DUMP]))
        self.assertEqual(protocol.encode_lcd_query(), protocol.encode_lcd_release())


class MiscCommandTest(unittest.TestCase):
    def test_measure(self):
        self.assertEqual(protocol.encode_measure(True), b"\x33\x01")
        self.assertEqual(protocol.encode_measure(False), b"\x33\x00")

    def test_reboot(self):
        self.assertEqual(protocol.encode_reboot(), b"\x72")


if __name__ == "__main__":
    unittest.main()
