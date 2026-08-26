"""段码屏渲染的测试。

关键的一组断言是字库要和固件 ``lcd_lywsd03mmc.c`` 里的
``display_numbers[]`` 完全一致——错一个 bit 屏幕上就是乱码。
"""

import unittest

from mijia_pc_monitor.device import lcd
from mijia_pc_monitor.device.lcd import Lcd03Frame

#: 固件 src/lcd_lywsd03mmc.c 的 display_numbers[]
FIRMWARE_DIGITS = [0xF5, 0x05, 0xD3, 0x97, 0x27, 0xB6, 0xF6, 0x15, 0xF7, 0xB7]
#: 固件里直接给出的几个字母段码
FIRMWARE_LETTERS = {"H": 0x67, "i": 0x40, "L": 0xE0, "o": 0xC6, "t": 0xE2, "h": 0x66}


class FontTest(unittest.TestCase):
    def test_digits_match_firmware(self):
        self.assertEqual([lcd.FONT[str(i)] for i in range(10)], FIRMWARE_DIGITS)

    def test_letters_match_firmware(self):
        for char, code in FIRMWARE_LETTERS.items():
            self.assertEqual(lcd.FONT[char], code, f"字母 {char!r} 段码不对")

    def test_unknown_char_is_blank(self):
        self.assertEqual(lcd.glyph("愛"), 0x00)

    def test_glyph_falls_back_to_other_case(self):
        # 字库里只有小写 't'，传大写也应该画得出来
        self.assertEqual(lcd.glyph("T"), lcd.FONT["t"])


class BufferTest(unittest.TestCase):
    def test_default_is_blank(self):
        self.assertEqual(Lcd03Frame().to_bytes(), b"\x00" * 6)

    def test_wrong_size_is_rejected(self):
        with self.assertRaises(ValueError):
            Lcd03Frame(b"\x00" * 18)

    def test_equality(self):
        self.assertEqual(Lcd03Frame().set_big_value(42), Lcd03Frame().set_big_value(42))
        self.assertNotEqual(Lcd03Frame().set_big_value(42), Lcd03Frame().set_big_value(43))


class BigValueTest(unittest.TestCase):
    def digits(self, frame):
        return (
            frame.data[lcd.IDX_BIG_HUNDREDS],
            frame.data[lcd.IDX_BIG_TENS],
            frame.data[lcd.IDX_BIG_ONES],
        )

    def test_two_digit_integer(self):
        frame = Lcd03Frame().set_big_value(42)
        self.assertEqual(self.digits(frame), (0x00, lcd.FONT["4"], lcd.FONT["2"]))

    def test_single_digit_has_no_leading_zero(self):
        frame = Lcd03Frame().set_big_value(7)
        self.assertEqual(self.digits(frame), (0x00, 0x00, lcd.FONT["7"]))

    def test_three_digit_integer(self):
        frame = Lcd03Frame().set_big_value(241)
        self.assertEqual(self.digits(frame), (lcd.FONT["2"], lcd.FONT["4"], lcd.FONT["1"]))

    def test_thousands_uses_dedicated_bar(self):
        # 屏幕最左边只有一根竖杠，只能表示 1xxx
        frame = Lcd03Frame().set_big_value(1234)
        self.assertTrue(frame.data[lcd.IDX_BIG_HUNDREDS] & lcd.BIT_THOUSANDS)
        self.assertEqual(
            frame.data[lcd.IDX_BIG_HUNDREDS] & ~lcd.BIT_THOUSANDS, lcd.FONT["2"]
        )

    def test_one_decimal_place(self):
        frame = Lcd03Frame().set_big_value(72.5, 1)
        self.assertTrue(frame.data[lcd.IDX_BIG_TENS] & lcd.BIT_POINT)
        self.assertEqual(frame.data[lcd.IDX_BIG_TENS] & ~lcd.BIT_POINT, lcd.FONT["2"])
        self.assertEqual(frame.data[lcd.IDX_BIG_ONES], lcd.FONT["5"])
        self.assertEqual(frame.data[lcd.IDX_BIG_HUNDREDS], lcd.FONT["7"])

    def test_decimal_keeps_leading_zero(self):
        # 0.5 不能显示成 ".5"
        frame = Lcd03Frame().set_big_value(0.5, 1)
        self.assertEqual(frame.data[lcd.IDX_BIG_TENS] & ~lcd.BIT_POINT, lcd.FONT["0"])

    def test_rounding(self):
        frame = Lcd03Frame().set_big_value(72.46, 1)
        self.assertEqual(frame.data[lcd.IDX_BIG_ONES], lcd.FONT["5"])
        self.assertEqual(Lcd03Frame().set_big_value(88.6).data[lcd.IDX_BIG_ONES], lcd.FONT["9"])

    def test_negative(self):
        frame = Lcd03Frame().set_big_value(-12)
        self.assertEqual(self.digits(frame), (lcd.SEG_G, lcd.FONT["1"], lcd.FONT["2"]))

    def test_negative_single_digit_keeps_the_sign_adjacent(self):
        # 负号要紧挨着数字（"-9"），中间空一格会看成两个符号
        frame = Lcd03Frame().set_big_value(-9)
        self.assertEqual(self.digits(frame), (0x00, lcd.SEG_G, lcd.FONT["9"]))

    def test_negative_with_decimal(self):
        frame = Lcd03Frame().set_big_value(-4.5, 1)
        self.assertEqual(frame.data[lcd.IDX_BIG_HUNDREDS], lcd.SEG_G)
        self.assertEqual(frame.data[lcd.IDX_BIG_TENS] & ~lcd.BIT_POINT, lcd.FONT["4"])
        self.assertEqual(frame.data[lcd.IDX_BIG_ONES], lcd.FONT["5"])

    def test_overflow_shows_hi(self):
        self.assertEqual(Lcd03Frame().set_big_value(2500), Lcd03Frame().set_big_text(" Hi"))
        self.assertEqual(Lcd03Frame().set_big_value(250.0, 1), Lcd03Frame().set_big_text(" Hi"))

    def test_underflow_shows_lo(self):
        self.assertEqual(Lcd03Frame().set_big_value(-150), Lcd03Frame().set_big_text(" Lo"))
        self.assertEqual(Lcd03Frame().set_big_value(-20.0, 1), Lcd03Frame().set_big_text(" Lo"))

    def test_missing_value_shows_dashes(self):
        frame = Lcd03Frame().set_big_value(None)
        self.assertEqual(self.digits(frame), (lcd.SEG_G, lcd.SEG_G, lcd.SEG_G))

    def test_only_zero_or_one_decimal(self):
        with self.assertRaises(ValueError):
            Lcd03Frame().set_big_value(1.23, 2)

    def test_text_is_right_aligned(self):
        frame = Lcd03Frame().set_big_text("Hi")
        self.assertEqual(self.digits(frame), (0x00, lcd.FONT["H"], lcd.FONT["i"]))


class SmallValueTest(unittest.TestCase):
    def test_two_digits(self):
        frame = Lcd03Frame().set_small_value(87)
        self.assertEqual(frame.data[lcd.IDX_SMALL_TENS], lcd.FONT["8"])
        self.assertEqual(frame.data[lcd.IDX_SMALL_ONES], lcd.FONT["7"])

    def test_single_digit_is_blank_padded(self):
        frame = Lcd03Frame().set_small_value(3)
        self.assertEqual(frame.data[lcd.IDX_SMALL_TENS], 0x00)
        self.assertEqual(frame.data[lcd.IDX_SMALL_ONES], lcd.FONT["3"])

    def test_percent_bit(self):
        frame = Lcd03Frame().set_small_value(50, percent=True)
        self.assertTrue(frame.data[lcd.IDX_SMALL_ONES] & lcd.BIT_PERCENT)

    def test_out_of_range(self):
        self.assertEqual(
            Lcd03Frame().set_small_value(120).data[lcd.IDX_SMALL_TENS], lcd.FONT["H"]
        )
        self.assertEqual(
            Lcd03Frame().set_small_value(-40).data[lcd.IDX_SMALL_TENS], lcd.FONT["L"]
        )

    def test_missing_value(self):
        frame = Lcd03Frame().set_small_value(None)
        self.assertEqual(frame.data[lcd.IDX_SMALL_TENS], lcd.SEG_G)
        self.assertEqual(frame.data[lcd.IDX_SMALL_ONES], lcd.SEG_G)

    def test_label(self):
        frame = Lcd03Frame().set_small_text("Cu")
        self.assertEqual(frame.data[lcd.IDX_SMALL_TENS], lcd.FONT["C"])
        self.assertEqual(frame.data[lcd.IDX_SMALL_ONES], lcd.FONT["u"])

    def test_label_keeps_battery_icon(self):
        # 电池图标和十位数字共用一个字节，写标签不能把它擦掉
        frame = Lcd03Frame().set_battery(True).set_small_text("GP")
        self.assertTrue(frame.data[lcd.IDX_SMALL_TENS] & lcd.BIT_BATTERY)


class SymbolTest(unittest.TestCase):
    def test_ble_bit(self):
        self.assertEqual(Lcd03Frame().set_ble(True).data[lcd.IDX_SYMBOLS], lcd.BIT_BLE)
        self.assertEqual(Lcd03Frame().set_ble(True).set_ble(False).data[lcd.IDX_SYMBOLS], 0)

    def test_smiley_and_temp_symbol_share_a_byte(self):
        frame = Lcd03Frame().set_smiley(5).set_temp_symbol(5)
        self.assertEqual(frame.data[lcd.IDX_SYMBOLS], 0x05 | 0xA0)
        # 改其中一个不能动到另一个
        frame.set_smiley(2)
        self.assertEqual(frame.data[lcd.IDX_SYMBOLS], 0x02 | 0xA0)
        frame.set_temp_symbol(3)
        self.assertEqual(frame.data[lcd.IDX_SYMBOLS], 0x02 | 0x60)


class AsciiRenderTest(unittest.TestCase):
    def test_render_is_stable(self):
        frame = (
            Lcd03Frame()
            .set_big_value(72.5, 1)
            .set_small_text("Ct", percent=False)
            .set_temp_symbol(5)
            .set_ble(True)
        )
        art = frame.render_ascii()
        self.assertIn("°C", art)
        self.assertIn("BLE", art)
        self.assertEqual(len(art.splitlines()), 7)  # 大号 3 行 + 小号 3 行 + 符号行

    def test_percent_marker(self):
        self.assertIn("%", Lcd03Frame().set_small_value(50, percent=True).render_ascii())

    def test_decimal_point_marker(self):
        self.assertIn(".", Lcd03Frame().set_big_value(9.9, 1).render_ascii())
        self.assertNotIn(".", Lcd03Frame().set_big_value(99).render_ascii())


if __name__ == "__main__":
    unittest.main()
