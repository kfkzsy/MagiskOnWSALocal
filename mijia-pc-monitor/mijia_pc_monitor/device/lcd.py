"""LYWSD03MMC 段码屏显存（6 字节）的渲染。

pvvx 固件的 ``CMD_LCD_DUMP`` 允许直接写显存，于是我们可以画出固件自身
画不出来的内容——比如在小号数字区写 ``Cu`` / ``GP`` 这样的标签，让用户
一眼看出当前这一屏是哪个指标。

显存布局取自固件 ``src/lcd_lywsd03mmc.c`` 的注释图（``字节.位``）::

         --5.4--         --4.4--            --3.4--          BLE
  |    |         |     |         |        |         |        2.4
  |   5.5       5.0   4.5       4.0      3.5       3.0
 5.3     --5.1--         --4.1--            --3.1--        笑脸 2.0-2.2
  |    |         |     |         |        |         |
  |   5.6       5.2   4.6       4.2      3.6       3.2      温度符号
         --5.7--         --4.7--     *      --3.7--          2.5-2.7
                                    4.3
                                        --1.4--         --0.4--
                                      |         |     |         |
                                     1.5       1.0   0.5       0.0
                                        --1.1--         --0.1--
                                      |         |     |         |
                                     1.6       1.2   0.6       0.2     %
                                        --1.7--         --0.7--       0.3
                           BAT 1.3

也就是说，每个数字位的 8 个 bit 含义一致（见 ``SEG_*``），另外三个 bit 被
复用为特殊符号：``5.3`` 是大号数字最左侧的"1"（千位），``4.3`` 是小数点，
``1.3`` 是电池图标，``0.3`` 是百分号。
"""

from __future__ import annotations

from typing import Final, Iterable

from ..rounding import round_half_up

# ------------------------------------------------------------ 段位定义 ----
SEG_A: Final = 0x10  # 上横
SEG_B: Final = 0x01  # 右上竖
SEG_C: Final = 0x04  # 右下竖
SEG_D: Final = 0x80  # 下横
SEG_E: Final = 0x40  # 左下竖
SEG_F: Final = 0x20  # 左上竖
SEG_G: Final = 0x02  # 中横

#: 显存大小；LYWSD03MMC 固定为 6 字节，其它型号不同，用它做型号校验
LCD_BUFFER_SIZE: Final = 6

# 字节索引
IDX_SMALL_ONES: Final = 0
IDX_SMALL_TENS: Final = 1
IDX_SYMBOLS: Final = 2
IDX_BIG_ONES: Final = 3
IDX_BIG_TENS: Final = 4
IDX_BIG_HUNDREDS: Final = 5

# 复用位
BIT_PERCENT: Final = 0x08  # 0.3
BIT_BATTERY: Final = 0x08  # 1.3
BIT_POINT: Final = 0x08  # 4.3 小数点
BIT_THOUSANDS: Final = 0x08  # 5.3 千位的"1"
BIT_BLE: Final = 0x10  # 2.4
MASK_SMILEY: Final = 0x07  # 2.0-2.2
MASK_TEMP_SYMBOL: Final = 0xE0  # 2.5-2.7

#: 七段字库。数字部分与固件的 ``display_numbers[]`` 完全一致。
FONT: Final = {
    " ": 0x00,
    "0": SEG_A | SEG_B | SEG_C | SEG_D | SEG_E | SEG_F,  # 0xF5
    "1": SEG_B | SEG_C,  # 0x05
    "2": SEG_A | SEG_B | SEG_D | SEG_E | SEG_G,  # 0xD3
    "3": SEG_A | SEG_B | SEG_C | SEG_D | SEG_G,  # 0x97
    "4": SEG_B | SEG_C | SEG_F | SEG_G,  # 0x27
    "5": SEG_A | SEG_C | SEG_D | SEG_F | SEG_G,  # 0xB6
    "6": SEG_A | SEG_C | SEG_D | SEG_E | SEG_F | SEG_G,  # 0xF6
    "7": SEG_A | SEG_B | SEG_C,  # 0x15
    "8": SEG_A | SEG_B | SEG_C | SEG_D | SEG_E | SEG_F | SEG_G,  # 0xF7
    "9": SEG_A | SEG_B | SEG_C | SEG_D | SEG_F | SEG_G,  # 0xB7
    "A": SEG_A | SEG_B | SEG_C | SEG_E | SEG_F | SEG_G,
    "b": SEG_C | SEG_D | SEG_E | SEG_F | SEG_G,
    "C": SEG_A | SEG_D | SEG_E | SEG_F,
    "c": SEG_D | SEG_E | SEG_G,
    "d": SEG_B | SEG_C | SEG_D | SEG_E | SEG_G,
    "E": SEG_A | SEG_D | SEG_E | SEG_F | SEG_G,
    "F": SEG_A | SEG_E | SEG_F | SEG_G,
    "G": SEG_A | SEG_C | SEG_D | SEG_E | SEG_F,
    "H": SEG_B | SEG_C | SEG_E | SEG_F | SEG_G,
    "h": SEG_C | SEG_E | SEG_F | SEG_G,
    "I": SEG_B | SEG_C,
    "i": SEG_E,
    "J": SEG_B | SEG_C | SEG_D | SEG_E,
    "L": SEG_D | SEG_E | SEG_F,
    "n": SEG_C | SEG_E | SEG_G,
    "O": SEG_A | SEG_B | SEG_C | SEG_D | SEG_E | SEG_F,
    "o": SEG_C | SEG_D | SEG_E | SEG_G,
    "P": SEG_A | SEG_B | SEG_E | SEG_F | SEG_G,
    "r": SEG_E | SEG_G,
    "S": SEG_A | SEG_C | SEG_D | SEG_F | SEG_G,
    "t": SEG_D | SEG_E | SEG_F | SEG_G,
    "U": SEG_B | SEG_C | SEG_D | SEG_E | SEG_F,
    "u": SEG_C | SEG_D | SEG_E,
    "y": SEG_B | SEG_C | SEG_D | SEG_F | SEG_G,
    "-": SEG_G,
    "_": SEG_D,
    "°": SEG_A | SEG_B | SEG_F | SEG_G,
}

#: 大号数字区能显示的整数范围（不带小数点）
BIG_INT_MAX: Final = 1999
BIG_INT_MIN: Final = -99
#: 带一位小数时的范围（千位的"1"仍可用，所以上限是 199.9）
BIG_DECIMAL_MAX: Final = 199.9
BIG_DECIMAL_MIN: Final = -9.9
#: 小号数字区的范围
SMALL_MAX: Final = 99
SMALL_MIN: Final = -9


def glyph(char: str) -> int:
    """取单个字符的段码；字库里没有的字符退化成空白。"""
    return FONT.get(char, FONT.get(char.upper(), FONT.get(char.lower(), 0x00)))


class Lcd03Frame:
    """一帧 LYWSD03MMC 显存。

    所有 ``set_*`` 方法都返回 ``self``，可以链式调用。
    """

    __slots__ = ("data",)

    def __init__(self, data: Iterable[int] | None = None) -> None:
        self.data = bytearray(LCD_BUFFER_SIZE)
        if data is not None:
            raw = bytes(data)
            if len(raw) != LCD_BUFFER_SIZE:
                raise ValueError(
                    f"LYWSD03MMC 显存应为 {LCD_BUFFER_SIZE} 字节，实际 {len(raw)}"
                )
            self.data[:] = raw

    # ------------------------------------------------------------ 大号区 ----
    def set_big_text(self, text: str) -> "Lcd03Frame":
        """在大号数字区写最多 3 个字符（右对齐），会清掉小数点和千位。"""
        text = text[-3:].rjust(3)
        self.data[IDX_BIG_HUNDREDS] = glyph(text[0])
        self.data[IDX_BIG_TENS] = glyph(text[1])
        self.data[IDX_BIG_ONES] = glyph(text[2])
        return self

    def set_big_value(self, value: float | None, decimals: int = 0) -> "Lcd03Frame":
        """在大号数字区显示数值。

        :param value: 数值；``None`` 显示 ``---`` 表示该指标取不到。
        :param decimals: 小数位数，只能是 0 或 1（硬件只有一个小数点）。

        超出硬件范围时显示 ``Hi`` / ``Lo``，与固件对溢出的处理保持一致。
        """
        if decimals not in (0, 1):
            raise ValueError("段码屏只有一个小数点，decimals 只能是 0 或 1")
        if value is None:
            return self.set_big_text("---")

        if decimals == 1:
            if value > BIG_DECIMAL_MAX:
                return self.set_big_text(" Hi")
            if value < BIG_DECIMAL_MIN:
                return self.set_big_text(" Lo")
            scaled = round_half_up(value * 10)
        else:
            if value > BIG_INT_MAX + 0.5:
                return self.set_big_text(" Hi")
            if value < BIG_INT_MIN - 0.5:
                return self.set_big_text(" Lo")
            scaled = round_half_up(value)

        negative = scaled < 0
        scaled = abs(scaled)
        # 负号占掉百位，所以负数只剩两位有效数字
        if negative and scaled > 99:
            return self.set_big_text(" Lo")

        ones = scaled % 10
        tens = scaled // 10 % 10
        hundreds = scaled // 100 % 10

        self.data[IDX_BIG_ONES] = glyph(str(ones))
        # 带小数点时个位是小数位，十位必须显示（0.5 而不是 .5）
        show_tens = scaled > 9 or decimals == 1
        self.data[IDX_BIG_TENS] = glyph(str(tens)) if show_tens else 0x00
        if scaled > 99:
            self.data[IDX_BIG_HUNDREDS] = glyph(str(hundreds))
        else:
            self.data[IDX_BIG_HUNDREDS] = 0x00
        if negative:
            # 负号紧挨着最高位，显示成 "-9" / "-12" 而不是中间空一格
            self.data[IDX_BIG_HUNDREDS if show_tens else IDX_BIG_TENS] = SEG_G
        if scaled > 999:
            self.data[IDX_BIG_HUNDREDS] |= BIT_THOUSANDS
        if decimals == 1:
            self.data[IDX_BIG_TENS] |= BIT_POINT
        return self

    # ------------------------------------------------------------ 小号区 ----
    def set_small_text(self, text: str, *, percent: bool = False) -> "Lcd03Frame":
        """在小号数字区写最多 2 个字符（右对齐），常用来放指标标签。"""
        text = text[-2:].rjust(2)
        battery = self.data[IDX_SMALL_TENS] & BIT_BATTERY
        self.data[IDX_SMALL_TENS] = glyph(text[0]) | battery
        self.data[IDX_SMALL_ONES] = glyph(text[1]) | (BIT_PERCENT if percent else 0)
        return self

    def set_small_value(
        self, value: float | None, *, percent: bool = False
    ) -> "Lcd03Frame":
        """在小号数字区显示 ``-9..99`` 的整数，``None`` 显示 ``--``。"""
        if value is None:
            return self.set_small_text("--", percent=percent)
        rounded = round_half_up(value)
        if rounded > SMALL_MAX:
            return self.set_small_text("Hi", percent=percent)
        if rounded < SMALL_MIN:
            return self.set_small_text("Lo", percent=percent)
        if rounded < 0:
            return self.set_small_text(f"-{abs(rounded)}", percent=percent)
        text = str(rounded) if rounded > 9 else f" {rounded}"
        return self.set_small_text(text, percent=percent)

    # ------------------------------------------------------------ 符号位 ----
    def set_percent(self, on: bool) -> "Lcd03Frame":
        return self._set_bit(IDX_SMALL_ONES, BIT_PERCENT, on)

    def set_battery(self, on: bool) -> "Lcd03Frame":
        return self._set_bit(IDX_SMALL_TENS, BIT_BATTERY, on)

    def set_ble(self, on: bool) -> "Lcd03Frame":
        return self._set_bit(IDX_SYMBOLS, BIT_BLE, on)

    def set_smiley(self, state: int) -> "Lcd03Frame":
        self.data[IDX_SYMBOLS] &= ~MASK_SMILEY & 0xFF
        self.data[IDX_SYMBOLS] |= state & MASK_SMILEY
        return self

    def set_temp_symbol(self, symbol: int) -> "Lcd03Frame":
        """设置温度符号，取值同 :mod:`protocol` 的 ``TEMP_SYMBOL_*``。"""
        self.data[IDX_SYMBOLS] &= ~MASK_TEMP_SYMBOL & 0xFF
        self.data[IDX_SYMBOLS] |= (symbol & 0x07) << 5
        return self

    def _set_bit(self, index: int, bit: int, on: bool) -> "Lcd03Frame":
        if on:
            self.data[index] |= bit
        else:
            self.data[index] &= ~bit & 0xFF
        return self

    # -------------------------------------------------------------- 输出 ----
    def to_bytes(self) -> bytes:
        return bytes(self.data)

    def __eq__(self, other: object) -> bool:
        if isinstance(other, Lcd03Frame):
            return self.data == other.data
        return NotImplemented

    def __repr__(self) -> str:
        return f"Lcd03Frame({self.to_bytes().hex(' ')})"

    def render_ascii(self) -> str:
        """把这一帧画成 ASCII 图，用于 ``preview`` 子命令和排错。"""
        big = [self.data[i] for i in (IDX_BIG_HUNDREDS, IDX_BIG_TENS, IDX_BIG_ONES)]
        small = [self.data[i] for i in (IDX_SMALL_TENS, IDX_SMALL_ONES)]
        # 复用位不属于字形，画之前先摘掉
        big[0] &= ~BIT_THOUSANDS & 0xFF
        big[1] &= ~BIT_POINT & 0xFF
        small[0] &= ~BIT_BATTERY & 0xFF
        small[1] &= ~BIT_PERCENT & 0xFF

        thousands = bool(self.data[IDX_BIG_HUNDREDS] & BIT_THOUSANDS)
        point = "." if self.data[IDX_BIG_TENS] & BIT_POINT else " "
        lead = ["  ", "| " if thousands else "  ", "| " if thousands else "  "]

        rows = []
        for line in range(3):
            cells = [_glyph_row(code, line) for code in big]
            rows.append(lead[line] + cells[0] + " " + cells[1] + (point if line == 2 else " ") + cells[2])
        pad = " " * 8
        for line in range(3):
            cells = [_glyph_row(code, line) for code in small]
            suffix = " %" if (self.data[IDX_SMALL_ONES] & BIT_PERCENT and line == 1) else ""
            rows.append(pad + cells[0] + " " + cells[1] + suffix)

        marks = []
        if self.data[IDX_SYMBOLS] & BIT_BLE:
            marks.append("BLE")
        if self.data[IDX_SMALL_TENS] & BIT_BATTERY:
            marks.append("BAT")
        smiley = self.data[IDX_SYMBOLS] & MASK_SMILEY
        if smiley:
            marks.append(_SMILEY_ART[smiley])
        temp_symbol = (self.data[IDX_SYMBOLS] & MASK_TEMP_SYMBOL) >> 5
        if temp_symbol:
            marks.append(_TEMP_SYMBOL_ART[temp_symbol])
        if marks:
            rows.append("  " + "  ".join(marks))
        return "\n".join(rows)


_SMILEY_ART: Final = {
    1: " ^_^ ",
    2: " -^- ",
    3: " ooo ",
    4: "(   )",
    5: "(^_^)",
    6: "(-^-)",
    7: "(ooo)",
}

_TEMP_SYMBOL_ART: Final = {
    1: "°Г",
    2: " -",
    3: "°F",
    4: " _",
    5: "°C",
    6: " =",
    7: "°E",
}


def _glyph_row(code: int, line: int) -> str:
    """把一个段码画成 3 行 ASCII 中的第 ``line`` 行。"""
    if line == 0:
        return " %s " % ("_" if code & SEG_A else " ")
    if line == 1:
        return "%s%s%s" % (
            "|" if code & SEG_F else " ",
            "_" if code & SEG_G else " ",
            "|" if code & SEG_B else " ",
        )
    return "%s%s%s" % (
        "|" if code & SEG_E else " ",
        "_" if code & SEG_D else " ",
        "|" if code & SEG_C else " ",
    )
