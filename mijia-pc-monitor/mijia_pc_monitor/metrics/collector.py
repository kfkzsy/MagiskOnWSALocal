"""把 CPU / GPU 采集器合到一起。"""

from __future__ import annotations

import logging
import platform

from .cpu import CpuMonitor
from .gpu import GpuMonitor
from .types import Reading, Snapshot
from .windows import HardwareMonitorBridge

log = logging.getLogger(__name__)


class MetricsCollector:
    """对外只暴露一个 :meth:`read`，返回一次完整采样。"""

    def __init__(self) -> None:
        # Windows 上 CPU 和 GPU 共用同一条 WMI 连接，每轮只查一次
        self._bridge = HardwareMonitorBridge() if platform.system() == "Windows" else None
        self.cpu = CpuMonitor(self._bridge)
        self.gpu = GpuMonitor(self._bridge)

    def describe(self) -> list[str]:
        """返回各数据源的说明，启动时打到日志里方便排错。"""
        return [self.cpu.describe(), self.gpu.describe()]

    def read(self) -> Snapshot:
        if self._bridge is not None:
            self._bridge.refresh()
        return Snapshot(cpu=self._safe(self.cpu.read), gpu=self._safe(self.gpu.read))

    @staticmethod
    def _safe(fn) -> Reading:
        """任何一路采集出错都不该中断刷新循环。"""
        try:
            return fn()
        except Exception as exc:  # noqa: BLE001
            log.warning("指标采集失败：%s", exc)
            return Reading()
