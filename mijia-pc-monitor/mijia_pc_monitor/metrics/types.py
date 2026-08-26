"""指标采集的数据结构。"""

from __future__ import annotations

import time
from dataclasses import dataclass, field


@dataclass(frozen=True)
class Reading:
    """一个部件（CPU 或 GPU）的一次读数。

    取不到的项一律是 ``None``——屏幕上会显示 ``---``，而不是假装是 0。
    """

    usage: float | None = None
    """占用率，百分比 0..100"""
    power_w: float | None = None
    """功耗，瓦"""
    temp_c: float | None = None
    """温度，摄氏度"""
    name: str | None = None
    """部件型号，仅用于日志"""

    def as_dict(self) -> dict:
        return {
            "usage": self.usage,
            "power_w": self.power_w,
            "temp_c": self.temp_c,
            "name": self.name,
        }


@dataclass(frozen=True)
class Snapshot:
    """一次完整采样。"""

    cpu: Reading = field(default_factory=Reading)
    gpu: Reading = field(default_factory=Reading)
    timestamp: float = field(default_factory=time.time)

    def as_dict(self) -> dict:
        return {
            "timestamp": self.timestamp,
            "cpu": self.cpu.as_dict(),
            "gpu": self.gpu.as_dict(),
        }
