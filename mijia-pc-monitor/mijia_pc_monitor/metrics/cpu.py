"""CPU 占用率 / 功耗 / 温度采集。

* 占用率：``psutil``，跨平台。
* 功耗：Linux 读 RAPL 能量计数器换算；Windows 走 LibreHardwareMonitor。
* 温度：Linux 用 ``psutil.sensors_temperatures()``；Windows 同上。
"""

from __future__ import annotations

import logging
import platform

from .sysfs import EnergyCounter, find_rapl_packages
from .types import Reading
from .windows import HardwareMonitorBridge

log = logging.getLogger(__name__)

#: 各家驱动里"整颗 CPU 温度"对应的标签，按优先级排列
TEMP_LABEL_HINTS = (
    "package id 0",  # Intel coretemp
    "tctl",  # AMD k10temp
    "tdie",  # AMD zenpower
    "cpu",
    "core 0",
)
#: ``sensors_temperatures()`` 的分组名，按优先级排列
TEMP_SOURCE_HINTS = ("coretemp", "k10temp", "zenpower", "cpu_thermal", "acpitz")


class CpuMonitor:
    """采集 CPU 指标。构造时会自动挑选可用的数据源。"""

    def __init__(self, bridge: HardwareMonitorBridge | None = None) -> None:
        self._bridge = bridge
        self._psutil = _import_psutil()
        self._rapl: list[EnergyCounter] = []
        self._name = _cpu_name()

        if platform.system() == "Linux":
            self._rapl = find_rapl_packages()
        if self._psutil is not None:
            # psutil 的 cpu_percent 是两次调用之间的均值，先打个底
            self._psutil.cpu_percent(interval=None)

    def describe(self) -> str:
        parts = []
        parts.append("占用率=psutil" if self._psutil else "占用率=不可用")
        if self._rapl:
            parts.append(f"功耗=RAPL({len(self._rapl)}域)")
        elif self._bridge is not None and self._bridge.available:
            parts.append(f"功耗={self._bridge.source_name}")
        else:
            parts.append("功耗=不可用")
        if self._temp_from_psutil() is not None:
            parts.append("温度=psutil")
        elif self._bridge is not None and self._bridge.available:
            parts.append(f"温度={self._bridge.source_name}")
        else:
            parts.append("温度=不可用")
        return "CPU: " + ", ".join(parts)

    def read(self) -> Reading:
        return Reading(
            usage=self._usage(),
            power_w=self._power(),
            temp_c=self._temp(),
            name=self._name,
        )

    # ------------------------------------------------------------------ ---
    def _usage(self) -> float | None:
        if self._psutil is not None:
            return float(self._psutil.cpu_percent(interval=None))
        if self._bridge is not None and self._bridge.available:
            return self._bridge.cpu_usage()
        return None

    def _power(self) -> float | None:
        if self._rapl:
            values = [counter.watts() for counter in self._rapl]
            usable = [v for v in values if v is not None]
            # 多路 CPU 要全部读到才有意义，缺一路就宁可不显示
            if usable and len(usable) == len(values):
                return sum(usable)
        if self._bridge is not None and self._bridge.available:
            return self._bridge.cpu_power()
        return None

    def _temp(self) -> float | None:
        value = self._temp_from_psutil()
        if value is not None:
            return value
        if self._bridge is not None and self._bridge.available:
            return self._bridge.cpu_temp()
        return None

    def _temp_from_psutil(self) -> float | None:
        if self._psutil is None or not hasattr(self._psutil, "sensors_temperatures"):
            return None
        try:
            groups = self._psutil.sensors_temperatures()
        except Exception as exc:  # noqa: BLE001 - psutil 在部分平台会直接抛
            log.debug("读取温度传感器失败：%s", exc)
            return None
        if not groups:
            return None

        ordered = [name for name in TEMP_SOURCE_HINTS if name in groups]
        ordered += [name for name in groups if name not in ordered]
        for source in ordered:
            entries = [e for e in groups[source] if e.current]
            if not entries:
                continue
            for hint in TEMP_LABEL_HINTS:
                for entry in entries:
                    if hint in (entry.label or "").lower():
                        return float(entry.current)
            if source in TEMP_SOURCE_HINTS:
                # 分组本身可信（比如 k10temp 只有一个无标签读数）
                return float(entries[0].current)
        return None


def _import_psutil():
    try:
        import psutil  # type: ignore[import-not-found]
    except ImportError:
        log.warning("未安装 psutil，CPU 占用率不可用（pip install psutil）")
        return None
    return psutil


def _cpu_name() -> str | None:
    if platform.system() == "Linux":
        try:
            with open("/proc/cpuinfo", encoding="utf-8") as handle:
                for line in handle:
                    if line.startswith("model name"):
                        return line.split(":", 1)[1].strip()
        except OSError:
            pass
    return platform.processor() or None
