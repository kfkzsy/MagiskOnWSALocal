"""GPU 占用率 / 功耗 / 温度采集。

按可用性依次尝试：

1. NVIDIA NVML（``nvidia-ml-py``），最准也最省开销；
2. ``nvidia-smi`` 命令行，装了驱动但没装 Python 绑定时的退路；
3. Linux DRM sysfs（AMD ``amdgpu``、部分 Intel 卡）；
4. Windows 的 LibreHardwareMonitor。
"""

from __future__ import annotations

import logging
import platform
import shutil
import subprocess
from pathlib import Path

from .sysfs import DRM_ROOT, read_int, read_text
from .types import Reading
from .windows import HardwareMonitorBridge

log = logging.getLogger(__name__)

#: ``nvidia-smi`` 单次查询的超时（秒）；驱动卡住时不能拖垮刷新循环
NVIDIA_SMI_TIMEOUT = 4.0


class GpuBackend:
    """GPU 数据源的公共接口。"""

    name = "none"

    def read(self) -> Reading:  # pragma: no cover - 接口定义
        raise NotImplementedError


class NvmlBackend(GpuBackend):
    """NVIDIA NVML。"""

    name = "NVML"

    def __init__(self) -> None:
        import pynvml  # type: ignore[import-not-found]

        self._nvml = pynvml
        self._nvml.nvmlInit()
        self._handle = self._nvml.nvmlDeviceGetHandleByIndex(0)
        raw_name = self._nvml.nvmlDeviceGetName(self._handle)
        self._name = raw_name.decode() if isinstance(raw_name, bytes) else str(raw_name)

    def read(self) -> Reading:
        return Reading(
            usage=self._try(lambda: float(self._nvml.nvmlDeviceGetUtilizationRates(self._handle).gpu)),
            power_w=self._try(
                lambda: self._nvml.nvmlDeviceGetPowerUsage(self._handle) / 1000.0
            ),
            temp_c=self._try(
                lambda: float(
                    self._nvml.nvmlDeviceGetTemperature(
                        self._handle, self._nvml.NVML_TEMPERATURE_GPU
                    )
                )
            ),
            name=self._name,
        )

    def _try(self, fn):
        """NVML 对不支持的项会抛 ``NVMLError_NotSupported``，逐项兜住。"""
        try:
            return fn()
        except Exception as exc:  # noqa: BLE001 - pynvml 的异常类型随版本变化
            log.debug("NVML 读数失败：%s", exc)
            return None


class NvidiaSmiBackend(GpuBackend):
    """调用 ``nvidia-smi``，作为没装 pynvml 时的退路。"""

    name = "nvidia-smi"
    QUERY = "utilization.gpu,power.draw,temperature.gpu,name"

    def __init__(self) -> None:
        self._exe = shutil.which("nvidia-smi")
        if not self._exe:
            raise RuntimeError("找不到 nvidia-smi")
        if self.read().usage is None:
            raise RuntimeError("nvidia-smi 无法返回有效读数")

    def read(self) -> Reading:
        try:
            output = subprocess.run(
                [self._exe, f"--query-gpu={self.QUERY}", "--format=csv,noheader,nounits"],
                capture_output=True,
                text=True,
                timeout=NVIDIA_SMI_TIMEOUT,
                check=True,
            ).stdout
        except (OSError, subprocess.SubprocessError) as exc:
            log.debug("nvidia-smi 调用失败：%s", exc)
            return Reading()
        return _parse_nvidia_smi(output)


class DrmSysfsBackend(GpuBackend):
    """Linux DRM sysfs，覆盖 AMD ``amdgpu`` 和部分 Intel 卡。"""

    name = "sysfs"

    def __init__(self) -> None:
        self._device = _find_drm_device()
        if self._device is None:
            raise RuntimeError("没有找到暴露 gpu_busy_percent 的 DRM 设备")
        self._hwmon = _find_device_hwmon(self._device)
        self._name = _drm_device_name(self._device)

    def read(self) -> Reading:
        usage = read_int(self._device / "gpu_busy_percent")
        power = temp = None
        if self._hwmon is not None:
            # power1_average 单位是微瓦；有的卡只有 power1_input
            micro_watts = read_int(self._hwmon / "power1_average")
            if micro_watts is None:
                micro_watts = read_int(self._hwmon / "power1_input")
            if micro_watts is not None:
                power = micro_watts / 1_000_000.0
            milli_celsius = read_int(self._hwmon / "temp1_input")
            if milli_celsius is not None:
                temp = milli_celsius / 1000.0
        return Reading(
            usage=None if usage is None else float(usage),
            power_w=power,
            temp_c=temp,
            name=self._name,
        )


class WindowsBackend(GpuBackend):
    """Windows 下从 LibreHardwareMonitor 取 GPU 数据。"""

    name = "LibreHardwareMonitor"

    def __init__(self, bridge: HardwareMonitorBridge) -> None:
        if not bridge.available:
            raise RuntimeError("LibreHardwareMonitor 不可用")
        self._bridge = bridge

    def read(self) -> Reading:
        return Reading(
            usage=self._bridge.gpu_usage(),
            power_w=self._bridge.gpu_power(),
            temp_c=self._bridge.gpu_temp(),
            name=self._bridge.gpu_name(),
        )


class GpuMonitor:
    """采集 GPU 指标；构造时挑第一个能用的后端。"""

    def __init__(self, bridge: HardwareMonitorBridge | None = None) -> None:
        self._backend = _select_backend(bridge)

    @property
    def backend_name(self) -> str:
        return self._backend.name if self._backend else "不可用"

    def describe(self) -> str:
        if self._backend is None:
            return "GPU: 不可用（没找到 NVML / nvidia-smi / sysfs / LibreHardwareMonitor）"
        return f"GPU: 数据源={self._backend.name}"

    def read(self) -> Reading:
        if self._backend is None:
            return Reading()
        try:
            return self._backend.read()
        except Exception as exc:  # noqa: BLE001 - 驱动出问题不该中断刷新循环
            log.warning("读取 GPU 指标失败：%s", exc)
            return Reading()


def _select_backend(bridge: HardwareMonitorBridge | None) -> GpuBackend | None:
    candidates: list[tuple[str, callable]] = [
        ("NVML", NvmlBackend),
        ("nvidia-smi", NvidiaSmiBackend),
    ]
    if platform.system() == "Linux":
        candidates.append(("sysfs", DrmSysfsBackend))
    if bridge is not None:
        candidates.append(("LibreHardwareMonitor", lambda: WindowsBackend(bridge)))

    for label, factory in candidates:
        try:
            backend = factory()
        except Exception as exc:  # noqa: BLE001 - 各后端失败方式不一
            log.debug("GPU 后端 %s 不可用：%s", label, exc)
            continue
        log.info("GPU 数据源：%s", label)
        return backend
    return None


def _parse_nvidia_smi(output: str) -> Reading:
    """解析 ``nvidia-smi`` 的 CSV 输出；只取第一张卡。

    取不到的项 nvidia-smi 会写 ``[N/A]`` 之类的占位符，一律转成 ``None``。
    """
    line = output.strip().splitlines()[0] if output.strip() else ""
    if not line:
        return Reading()
    fields = [f.strip() for f in line.split(",")]
    fields += [""] * (4 - len(fields))

    def number(text: str) -> float | None:
        try:
            return float(text)
        except ValueError:
            return None

    return Reading(
        usage=number(fields[0]),
        power_w=number(fields[1]),
        temp_c=number(fields[2]),
        name=fields[3] or None,
    )


def _find_drm_device() -> Path | None:
    if not DRM_ROOT.is_dir():
        return None
    for card in sorted(DRM_ROOT.glob("card[0-9]*")):
        device = card / "device"
        if (device / "gpu_busy_percent").exists():
            return device
    return None


def _find_device_hwmon(device: Path) -> Path | None:
    hwmon_root = device / "hwmon"
    if not hwmon_root.is_dir():
        return None
    for entry in sorted(hwmon_root.iterdir()):
        if (entry / "temp1_input").exists() or (entry / "power1_average").exists():
            return entry
    return None


def _drm_device_name(device: Path) -> str | None:
    # sysfs 只给 PCI ID，型号名要查表，这里保留原始 ID 足够排错用了
    vendor = read_text(device / "vendor")
    model = read_text(device / "device")
    if vendor and model:
        return f"PCI {vendor}:{model}"
    return None
