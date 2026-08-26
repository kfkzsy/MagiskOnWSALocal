"""Linux ``sysfs`` 读数的小工具。"""

from __future__ import annotations

import logging
import time
from pathlib import Path

log = logging.getLogger(__name__)

POWERCAP_ROOT = Path("/sys/class/powercap")
DRM_ROOT = Path("/sys/class/drm")


def read_text(path: Path) -> str | None:
    """读取一个 sysfs 节点；读不到（不存在 / 没权限）返回 ``None``。"""
    try:
        return path.read_text().strip()
    except (OSError, ValueError):
        return None


def read_int(path: Path) -> int | None:
    raw = read_text(path)
    if raw is None:
        return None
    try:
        return int(raw)
    except ValueError:
        return None


class EnergyCounter:
    """把单调递增的能量计数器换算成平均功率。

    RAPL 只给累计能量（微焦），功率得由两次读数的差值除以时间间隔得到，
    所以第一次调用 :meth:`watts` 必然返回 ``None``。计数器会回绕，
    ``max_energy_range_uj`` 给出回绕点。
    """

    def __init__(self, energy_path: Path, max_range_path: Path | None = None) -> None:
        self.energy_path = energy_path
        self.max_range = read_int(max_range_path) if max_range_path else None
        self._last_uj: int | None = None
        self._last_ts: float | None = None

    def watts(self) -> float | None:
        now = time.monotonic()
        current = read_int(self.energy_path)
        if current is None:
            self._last_uj = None
            return None

        previous, previous_ts = self._last_uj, self._last_ts
        self._last_uj, self._last_ts = current, now
        if previous is None or previous_ts is None:
            return None

        elapsed = now - previous_ts
        if elapsed <= 0:
            return None

        delta = current - previous
        if delta < 0:
            # 计数器回绕
            if not self.max_range:
                return None
            delta += self.max_range
        return delta / 1_000_000.0 / elapsed


def find_rapl_packages() -> list[EnergyCounter]:
    """找出所有 CPU 封装级的 RAPL 能量域。

    Intel 和 AMD（内核 5.11 起）都通过 ``intel-rapl`` 这套接口暴露，
    域名形如 ``package-0``。多路 CPU 会有多个域，功耗需要相加。
    """
    counters: list[EnergyCounter] = []
    if not POWERCAP_ROOT.is_dir():
        return counters
    for domain in sorted(POWERCAP_ROOT.iterdir()):
        name = read_text(domain / "name")
        if not name or not name.startswith("package"):
            continue
        energy = domain / "energy_uj"
        if not energy.exists():
            continue
        if read_int(energy) is None:
            log.warning(
                "RAPL 能量计数器 %s 读不到（通常是权限问题），CPU 功耗将不可用。"
                "可以用 root 运行，或执行 "
                "sudo chmod +r %s",
                energy,
                energy,
            )
            continue
        counters.append(EnergyCounter(energy, domain / "max_energy_range_uj"))
    return counters
