"""Windows 下通过 LibreHardwareMonitor / OpenHardwareMonitor 取传感器数据。

Windows 没有 Linux 那样的 ``sysfs``，功耗和温度必须借助已经在跑的
LibreHardwareMonitor（勾选 Options → Remote Web Server 不是必需的，
但要勾上 "WMI Provider"）。本模块用 WMI 查询它发布的 ``Sensor`` 类。

依赖 ``wmi`` 包（仅 Windows 需要）；不可用时整个后端安静地退化为不可用。
"""

from __future__ import annotations

import logging
from typing import Final

log = logging.getLogger(__name__)

#: LibreHardwareMonitor 优先，装的是老版 OpenHardwareMonitor 也能用
NAMESPACES: Final = (
    "root\\LibreHardwareMonitor",
    "root\\OpenHardwareMonitor",
)

CPU_PREFIXES: Final = ("/amdcpu", "/intelcpu", "/cpu")
GPU_PREFIXES: Final = ("/gpu-nvidia", "/gpu-amd", "/gpu-intel", "/nvidiagpu", "/atigpu")


class HardwareMonitorBridge:
    """一次 WMI 查询取回全部传感器，再按需筛选。

    每次 :meth:`refresh` 只查一次，避免 CPU/GPU 两个采集器各查一遍。
    """

    def __init__(self) -> None:
        self._connection = None
        self._namespace: str | None = None
        self._sensors: list[dict] = []
        self._connect()

    @property
    def available(self) -> bool:
        return self._connection is not None

    @property
    def source_name(self) -> str:
        return self._namespace.rsplit("\\", 1)[-1] if self._namespace else "unavailable"

    def _connect(self) -> None:
        try:
            import wmi  # type: ignore[import-not-found]
        except ImportError:
            log.debug("未安装 wmi 包，跳过 LibreHardwareMonitor 后端")
            return
        for namespace in NAMESPACES:
            try:
                connection = wmi.WMI(namespace=namespace)
                connection.Sensor()  # 探一下，命名空间在但服务没跑时这里会失败
            except Exception:  # noqa: BLE001 - wmi 抛的异常类型不稳定
                continue
            self._connection = connection
            self._namespace = namespace
            log.info("已连接 %s", namespace)
            return
        log.debug("未找到运行中的 LibreHardwareMonitor/OpenHardwareMonitor")

    def refresh(self) -> None:
        if self._connection is None:
            return
        try:
            self._sensors = [
                {
                    "identifier": str(s.Identifier or ""),
                    "name": str(s.Name or ""),
                    "type": str(s.SensorType or ""),
                    "value": None if s.Value is None else float(s.Value),
                }
                for s in self._connection.Sensor()
            ]
        except Exception as exc:  # noqa: BLE001
            log.warning("读取硬件传感器失败：%s", exc)
            self._sensors = []

    def _pick(
        self,
        prefixes: tuple[str, ...],
        sensor_type: str,
        name_hints: tuple[str, ...],
    ) -> float | None:
        """在指定硬件下按名字优先级挑一个传感器。

        ``name_hints`` 按优先级排列，命中越靠前的越好；都没命中就退而
        求其次用该类型的第一个传感器（例如非标准命名的第三方主板）。
        """
        candidates = [
            s
            for s in self._sensors
            if s["type"] == sensor_type
            and s["value"] is not None
            and s["identifier"].startswith(prefixes)
        ]
        if not candidates:
            return None
        for hint in name_hints:
            for sensor in candidates:
                if hint.lower() in sensor["name"].lower():
                    return sensor["value"]
        return candidates[0]["value"]

    def cpu_usage(self) -> float | None:
        return self._pick(CPU_PREFIXES, "Load", ("CPU Total",))

    def cpu_power(self) -> float | None:
        return self._pick(CPU_PREFIXES, "Power", ("CPU Package", "Package", "CPU"))

    def cpu_temp(self) -> float | None:
        return self._pick(
            CPU_PREFIXES, "Temperature", ("CPU Package", "Core Average", "Tctl", "CPU")
        )

    def gpu_usage(self) -> float | None:
        return self._pick(GPU_PREFIXES, "Load", ("GPU Core",))

    def gpu_power(self) -> float | None:
        return self._pick(GPU_PREFIXES, "Power", ("GPU Package", "GPU Power", "GPU"))

    def gpu_temp(self) -> float | None:
        return self._pick(GPU_PREFIXES, "Temperature", ("GPU Core", "GPU Hot Spot"))

    def gpu_name(self) -> str | None:
        for sensor in self._sensors:
            if sensor["identifier"].startswith(GPU_PREFIXES):
                return sensor["identifier"].split("/")[1] if "/" in sensor["identifier"] else None
        return None
