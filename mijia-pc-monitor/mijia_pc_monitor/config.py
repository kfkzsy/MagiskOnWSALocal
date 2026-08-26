"""配置文件读取。

配置用 TOML（Python 3.11 起标准库自带 ``tomllib``），查找顺序：

1. ``--config`` 指定的路径；
2. 环境变量 ``MIJIA_PC_MONITOR_CONFIG``；
3. ``~/.config/mijia-pc-monitor/config.toml``；
4. 当前目录下的 ``config.toml``。

全部找不到时用内置默认值，只要命令行给了 ``--address`` 就能跑。
"""

from __future__ import annotations

import os
import tomllib
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Any

from .render import DEFAULT_PAGES, resolve_pages

ENV_CONFIG_PATH = "MIJIA_PC_MONITOR_CONFIG"

DEFAULT_CONFIG_PATHS = (
    Path.home() / ".config" / "mijia-pc-monitor" / "config.toml",
    Path("config.toml"),
)

#: 显示模式
MODE_AUTO = "auto"
MODE_LCD = "lcd"
MODE_EXT = "ext"
MODES = (MODE_AUTO, MODE_LCD, MODE_EXT)


@dataclass(frozen=True)
class DeviceConfig:
    address: str | None = None
    """设备 MAC（Linux/Windows）或 UUID（macOS）；不填则扫描时按名字匹配"""
    adapter: str | None = None
    """指定蓝牙适配器，例如 Linux 上的 ``hci1``"""
    name_prefix: str = "ATC_"
    """扫描时用的名字前缀，pvvx 固件默认广播名是 ``ATC_xxxxxx``"""
    connect_timeout: float = 20.0
    scan_timeout: float = 8.0


@dataclass(frozen=True)
class DisplayConfig:
    mode: str = MODE_AUTO
    pages: tuple[str, ...] = DEFAULT_PAGES
    interval: float = 2.0
    """采样并刷新屏幕的周期（秒）"""
    dwell: float = 4.0
    """每一页停留的时间（秒）"""
    show_ble_icon: bool = True
    """``lcd`` 模式下是否点亮蓝牙图标，用来确认连接还活着"""

    def hold_seconds(self) -> int:
        """``ext`` 模式下外部数据的有效期。

        必须明显长于刷新周期，否则两次刷新之间屏幕会闪回自身的温湿度；
        又不能太长，否则程序被强杀后屏幕会长时间停在最后一帧。
        """
        return max(5, int(self.interval * 4))


@dataclass(frozen=True)
class AppConfig:
    device: DeviceConfig = field(default_factory=DeviceConfig)
    display: DisplayConfig = field(default_factory=DisplayConfig)
    log_level: str = "INFO"

    def validate(self) -> "AppConfig":
        if self.display.mode not in MODES:
            raise ValueError(
                f"未知的显示模式 {self.display.mode!r}，可用：{', '.join(MODES)}"
            )
        if self.display.interval <= 0:
            raise ValueError("interval 必须大于 0")
        if self.display.dwell <= 0:
            raise ValueError("dwell 必须大于 0")
        resolve_pages(self.display.pages)  # 页面名写错时在启动阶段就报出来
        return self


def find_config_file(explicit: str | os.PathLike[str] | None = None) -> Path | None:
    if explicit is not None:
        path = Path(explicit)
        if not path.is_file():
            raise FileNotFoundError(f"配置文件不存在：{path}")
        return path
    env_path = os.environ.get(ENV_CONFIG_PATH)
    if env_path:
        path = Path(env_path)
        if not path.is_file():
            raise FileNotFoundError(f"{ENV_CONFIG_PATH} 指向的配置文件不存在：{path}")
        return path
    for candidate in DEFAULT_CONFIG_PATHS:
        if candidate.is_file():
            return candidate
    return None


def load_config(path: str | os.PathLike[str] | None = None) -> AppConfig:
    """读取配置文件；没有配置文件就返回默认配置。"""
    config_file = find_config_file(path)
    if config_file is None:
        return AppConfig().validate()
    with open(config_file, "rb") as handle:
        return from_dict(tomllib.load(handle))


def from_dict(data: dict[str, Any]) -> AppConfig:
    device_data = data.get("device", {})
    display_data = data.get("display", {})
    defaults = AppConfig()

    device = DeviceConfig(
        address=device_data.get("address", defaults.device.address),
        adapter=device_data.get("adapter", defaults.device.adapter),
        name_prefix=device_data.get("name_prefix", defaults.device.name_prefix),
        connect_timeout=float(
            device_data.get("connect_timeout", defaults.device.connect_timeout)
        ),
        scan_timeout=float(device_data.get("scan_timeout", defaults.device.scan_timeout)),
    )
    display = DisplayConfig(
        mode=str(display_data.get("mode", defaults.display.mode)).lower(),
        pages=tuple(display_data.get("pages", defaults.display.pages)),
        interval=float(display_data.get("interval", defaults.display.interval)),
        dwell=float(display_data.get("dwell", defaults.display.dwell)),
        show_ble_icon=bool(
            display_data.get("show_ble_icon", defaults.display.show_ble_icon)
        ),
    )
    log_level = str(data.get("logging", {}).get("level", defaults.log_level)).upper()
    return AppConfig(device=device, display=display, log_level=log_level).validate()


def apply_overrides(config: AppConfig, **overrides: Any) -> AppConfig:
    """用命令行参数覆盖配置文件的值；``None`` 表示命令行没给这一项。"""
    device_keys = {"address", "adapter", "connect_timeout", "scan_timeout"}
    display_keys = {"mode", "pages", "interval", "dwell", "show_ble_icon"}

    device_updates = {k: v for k, v in overrides.items() if k in device_keys and v is not None}
    display_updates = {k: v for k, v in overrides.items() if k in display_keys and v is not None}
    if "pages" in display_updates:
        display_updates["pages"] = tuple(display_updates["pages"])

    updated = config
    if device_updates:
        updated = replace(updated, device=replace(updated.device, **device_updates))
    if display_updates:
        updated = replace(updated, display=replace(updated.display, **display_updates))
    if overrides.get("log_level") is not None:
        updated = replace(updated, log_level=str(overrides["log_level"]).upper())
    return updated.validate()
