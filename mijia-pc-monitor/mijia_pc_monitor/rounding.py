"""数值取整。

Python 内置的 :func:`round` 用的是"银行家舍入"（``round(72.5) == 72``、
``round(73.5) == 74``），显示温度这类 0.5 步进的读数时看起来会很别扭。
屏幕上要的是常识里的四舍五入。
"""

from __future__ import annotations

import math

__all__ = ["round_half_up"]


def round_half_up(value: float) -> int:
    """四舍五入到整数；负数按绝对值舍入（``-2.5`` → ``-3``）。"""
    if value >= 0:
        return int(math.floor(value + 0.5))
    return -int(math.floor(-value + 0.5))
