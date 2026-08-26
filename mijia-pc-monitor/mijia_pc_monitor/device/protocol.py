"""pvvx ATC_MiThermometer 自定义固件的 BLE 命令编码。

全部是纯函数，不依赖 bleak，方便单元测试。

固件侧参考实现（v5.x）：

* GATT: Primary Service ``0x1F10`` / Characteristic ``0x1F1F`` (Write + Notify)。
  所有命令都写入这一个特征值，第 1 字节是命令号，其余是负载；固件通过
  Notify 回送同一命令号的应答。
* ``CMD_EXT_DATA (0x22)`` 让屏幕显示外部数据，负载即 ``external_data_t``：

  .. code-block:: c

      typedef struct __attribute__((packed)) _external_data_t {
          s16 big_number;     // -995..19995, x0.1
          s16 small_number;   // -9..99, x1
          u16 vtime_sec;      // 有效期(秒)，0xffff = 永久
          struct __attribute__((packed)) {
              u8 smiley       : 3;
              u8 percent_on   : 1;
              u8 battery      : 1;
              u8 temp_symbol  : 3;
          } flg;
      } external_data_t;

* ``CMD_LCD_DUMP (0x60)`` 直接写入段码屏的显存（LYWSD03MMC 为 6 字节），
  可以画出固件本身画不出来的字符（例如 ``Cu`` / ``GP`` 这类标签）。
  负载为空时表示"释放显存并回读当前内容"。
"""

from __future__ import annotations

import struct
from typing import Final

#: 自定义固件的私有服务
SERVICE_UUID: Final = "00001f10-0000-1000-8000-00805f9b34fb"
#: 命令特征值（Write + Notify）
CHAR_UUID: Final = "00001f1f-0000-1000-8000-00805f9b34fb"

# ---------------------------------------------------------------- 命令号 ----
CMD_DEV_NAME: Final = 0x01
CMD_COMFORT: Final = 0x20
CMD_EXT_DATA: Final = 0x22
CMD_MEASURE: Final = 0x33
CMD_CFG: Final = 0x55
CMD_LCD_DUMP: Final = 0x60
CMD_LCD_FLAGS: Final = 0x61
CMD_REBOOT: Final = 0x72

# ------------------------------------------------------------ 温度符号位 ----
TEMP_SYMBOL_NONE: Final = 0  # "  "
TEMP_SYMBOL_DEG_G: Final = 1  # "°Г"
TEMP_SYMBOL_MINUS: Final = 2  # " -"
TEMP_SYMBOL_F: Final = 3  # "°F"
TEMP_SYMBOL_UNDERSCORE: Final = 4  # " _"
TEMP_SYMBOL_C: Final = 5  # "°C"
TEMP_SYMBOL_EQ: Final = 6  # " ="
TEMP_SYMBOL_E: Final = 7  # "°E"

# -------------------------------------------------------------- 笑脸图案 ----
SMILEY_OFF: Final = 0
SMILEY_BROW: Final = 1  # " ^_^ "
SMILEY_FLAT: Final = 2  # " -^- "
SMILEY_DOTS: Final = 3  # " ooo "
SMILEY_RING: Final = 4  # "(   )"
SMILEY_HAPPY: Final = 5  # "(^_^)"
SMILEY_SAD: Final = 6  # "(-^-)"
SMILEY_ANGRY: Final = 7  # "(ooo)"

#: ``big_number`` 的取值范围（0.1 为单位）
BIG_NUMBER_MIN: Final = -995
BIG_NUMBER_MAX: Final = 19995
#: ``small_number`` 的取值范围
SMALL_NUMBER_MIN: Final = -9
SMALL_NUMBER_MAX: Final = 99
#: ``vtime_sec`` 取该值时显示内容永不过期
VTIME_FOREVER: Final = 0xFFFF


def _clamp(value: int, low: int, high: int) -> int:
    return low if value < low else high if value > high else value


def encode_ext_data(
    big_number_x10: int,
    small_number: int,
    vtime_sec: int = 60,
    *,
    smiley: int = SMILEY_OFF,
    percent: bool = False,
    battery: bool = False,
    temp_symbol: int = TEMP_SYMBOL_NONE,
) -> bytes:
    """编码 ``CMD_EXT_DATA``，让固件把外部数值画到屏幕上。

    :param big_number_x10: 大号数字，单位 0.1（``456`` 显示为 ``45.6``）。
    :param small_number: 小号数字，整数 ``-9..99``。
    :param vtime_sec: 有效期（秒）。超时后屏幕会恢复显示自身温湿度，
        因此它必须大于刷新周期；``VTIME_FOREVER`` 表示永不过期。
    :param smiley: ``SMILEY_*`` 之一。
    :param percent: 是否点亮 ``%`` 符号。
    :param battery: 是否点亮电池图标。
    :param temp_symbol: ``TEMP_SYMBOL_*`` 之一。

    超出硬件范围的数值会被截断而不是抛异常——监控场景下宁可显示到边界值，
    也不要因为一次异常读数把整个刷新循环打断。
    """
    flags = (
        (smiley & 0x07)
        | (0x08 if percent else 0)
        | (0x10 if battery else 0)
        | ((temp_symbol & 0x07) << 5)
    )
    return bytes([CMD_EXT_DATA]) + struct.pack(
        "<hhHB",
        _clamp(int(big_number_x10), BIG_NUMBER_MIN, BIG_NUMBER_MAX),
        _clamp(int(small_number), SMALL_NUMBER_MIN, SMALL_NUMBER_MAX),
        _clamp(int(vtime_sec), 0, VTIME_FOREVER),
        flags,
    )


def encode_ext_data_release() -> bytes:
    """让外部数据立刻过期，屏幕恢复显示温湿度。"""
    return encode_ext_data(0, 0, vtime_sec=0)


def decode_ext_data(payload: bytes) -> dict:
    """解析 ``CMD_EXT_DATA`` 的应答（去掉命令号后的 7 字节）。"""
    if len(payload) < 7:
        raise ValueError(f"ext data 负载长度应为 7，实际 {len(payload)}")
    big, small, vtime, flags = struct.unpack("<hhHB", payload[:7])
    return {
        "big_number_x10": big,
        "small_number": small,
        "vtime_sec": vtime,
        "smiley": flags & 0x07,
        "percent": bool(flags & 0x08),
        "battery": bool(flags & 0x10),
        "temp_symbol": (flags >> 5) & 0x07,
    }


def encode_lcd_dump(buffer: bytes) -> bytes:
    """编码 ``CMD_LCD_DUMP``，直接写入段码屏显存。"""
    if not buffer:
        raise ValueError("显存内容不能为空，释放显存请用 encode_lcd_release()")
    return bytes([CMD_LCD_DUMP]) + bytes(buffer)


def encode_lcd_release() -> bytes:
    """释放对显存的接管；固件会回送当前显存内容。

    这条命令同时也是"查询显存"命令——固件对空负载的处理是先清除接管标志，
    再把显存 Notify 回来，因此可以用应答长度来判断设备型号的显存大小。
    """
    return bytes([CMD_LCD_DUMP])


#: :func:`encode_lcd_release` 的别名，用于表达"只是想读一下显存"的意图
encode_lcd_query = encode_lcd_release


def encode_measure(notify: bool = True) -> bytes:
    """开关连接状态下的测量值 Notify（应答里带电量、电压等）。"""
    return bytes([CMD_MEASURE, 1 if notify else 0])


def encode_reboot() -> bytes:
    """断开连接后重启设备（恢复固件默认显示的兜底手段）。"""
    return bytes([CMD_REBOOT])
