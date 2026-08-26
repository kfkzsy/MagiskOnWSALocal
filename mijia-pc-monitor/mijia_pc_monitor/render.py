"""把一次采样渲染成温湿度计屏幕上的一"页"。

屏幕只有"一个大号数字 + 一个小号数字"，六个指标（CPU/GPU 各三项）
放不下，所以做成轮播：每页显示一个主指标，隔几秒换一页。

两种显示模式：

``lcd``
    直接写显存（``CMD_LCD_DUMP``）。小号数字区被拿来写两个字母当标签
    （``Cu`` = CPU 占用率、``GP`` = GPU 功耗……），一眼能看出当前是哪项。
    只适用于 LYWSD03MMC 这种 6 字节显存的型号。
``ext``
    用固件自带的 ``CMD_EXT_DATA``。没有文字标签，于是小号数字区改放一个
    辅助指标（占用率或温度），靠 ``°C`` / ``%`` 符号区分页面。兼容
    pvvx 支持的所有带屏型号。
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Final, Iterable, Sequence

from .device import protocol
from .device.lcd import Lcd03Frame
from .metrics.types import Snapshot
from .rounding import round_half_up

#: 占用率高于该值时笑脸变"生气"
LOAD_HIGH: Final = 85.0
#: 占用率高于该值时笑脸变"一般"
LOAD_MEDIUM: Final = 60.0


@dataclass(frozen=True)
class MetricRef:
    """指向一次采样里的某个具体读数。"""

    component: str  # "cpu" 或 "gpu"
    field: str  # "usage" / "power_w" / "temp_c"

    def get(self, snapshot: Snapshot) -> float | None:
        reading = getattr(snapshot, self.component)
        return getattr(reading, self.field)

    @property
    def is_usage(self) -> bool:
        return self.field == "usage"

    @property
    def is_temp(self) -> bool:
        return self.field == "temp_c"


@dataclass(frozen=True)
class Page:
    """一页显示内容的定义。"""

    key: str
    title: str
    label: str
    """``lcd`` 模式下写在小号数字区的两字符标签"""
    primary: MetricRef
    """大号数字区显示的指标"""
    secondary: MetricRef
    """``ext`` 模式下小号数字区显示的辅助指标"""
    decimals: int = 0
    """大号数字区的小数位数"""

    def temp_symbol(self) -> int:
        return protocol.TEMP_SYMBOL_C if self.primary.is_temp else protocol.TEMP_SYMBOL_NONE


def _page(key: str, title: str, label: str, component: str, field: str, secondary_field: str, decimals: int) -> Page:
    return Page(
        key=key,
        title=title,
        label=label,
        primary=MetricRef(component, field),
        secondary=MetricRef(component, secondary_field),
        decimals=decimals,
    )


#: 全部可选页面。温度带一位小数，占用率和功耗取整（瓦数可能超过 100）。
PAGES: Final[dict[str, Page]] = {
    p.key: p
    for p in (
        _page("cpu_usage", "CPU 占用率", "Cu", "cpu", "usage", "temp_c", 0),
        _page("cpu_power", "CPU 功耗", "CP", "cpu", "power_w", "usage", 0),
        _page("cpu_temp", "CPU 温度", "Ct", "cpu", "temp_c", "usage", 1),
        _page("gpu_usage", "GPU 占用率", "Gu", "gpu", "usage", "temp_c", 0),
        _page("gpu_power", "GPU 功耗", "GP", "gpu", "power_w", "usage", 0),
        _page("gpu_temp", "GPU 温度", "Gt", "gpu", "temp_c", "usage", 1),
    )
}

#: 默认轮播顺序：先 CPU 三项，再 GPU 三项
DEFAULT_PAGES: Final[tuple[str, ...]] = (
    "cpu_usage",
    "cpu_power",
    "cpu_temp",
    "gpu_usage",
    "gpu_power",
    "gpu_temp",
)


def resolve_pages(names: Iterable[str]) -> list[Page]:
    """把配置里的页面名解析成 :class:`Page`，名字写错时给出可用列表。"""
    pages = []
    for name in names:
        try:
            pages.append(PAGES[name])
        except KeyError:
            raise ValueError(
                f"未知的页面 {name!r}，可用的有：{', '.join(PAGES)}"
            ) from None
    if not pages:
        raise ValueError("至少要启用一个页面")
    return pages


def smiley_for_load(usage: float | None) -> int:
    """用笑脸表示负载高低——这本来就是固件给"舒适度"留的图标。"""
    if usage is None:
        return protocol.SMILEY_OFF
    if usage >= LOAD_HIGH:
        return protocol.SMILEY_ANGRY
    if usage >= LOAD_MEDIUM:
        return protocol.SMILEY_RING
    return protocol.SMILEY_HAPPY


def render_lcd(page: Page, snapshot: Snapshot, *, ble: bool = True) -> Lcd03Frame:
    """``lcd`` 模式：大号区放数值，小号区放两字符标签。"""
    value = page.primary.get(snapshot)
    frame = Lcd03Frame()
    frame.set_big_value(value, page.decimals)
    frame.set_small_text(page.label, percent=page.primary.is_usage)
    frame.set_temp_symbol(page.temp_symbol())
    frame.set_smiley(smiley_for_load(getattr(snapshot, page.primary.component).usage))
    frame.set_ble(ble)
    return frame


def render_ext(page: Page, snapshot: Snapshot, *, hold_seconds: int) -> bytes:
    """``ext`` 模式：大号区放主指标，小号区放辅助指标。"""
    value = page.primary.get(snapshot)
    secondary = page.secondary.get(snapshot)
    return protocol.encode_ext_data(
        big_number_x10=0 if value is None else round_half_up(value * 10),
        small_number=0 if secondary is None else round_half_up(secondary),
        vtime_sec=hold_seconds,
        smiley=smiley_for_load(getattr(snapshot, page.primary.component).usage),
        percent=page.secondary.is_usage and secondary is not None,
        temp_symbol=page.temp_symbol(),
    )


def format_page(page: Page, snapshot: Snapshot) -> str:
    """给日志和 ``preview`` 用的一行文字描述。"""
    value = page.primary.get(snapshot)
    unit = {"usage": "%", "power_w": " W", "temp_c": " °C"}[page.primary.field]
    text = "--" if value is None else f"{value:.{page.decimals}f}"
    return f"{page.title}: {text}{unit}"


class PageRotator:
    """按固定时长轮播页面，自动跳过读不到数的页面。

    某个指标取不到（比如没有独显、或者没权限读 RAPL）时，与其在屏幕上
    闪一下 ``---``，不如直接跳过那一页。
    """

    def __init__(self, pages: Sequence[Page], dwell_seconds: float) -> None:
        if not pages:
            raise ValueError("至少要启用一个页面")
        self._pages = list(pages)
        self._dwell = max(0.5, float(dwell_seconds))
        self._index = 0
        self._switched_at: float | None = None

    @property
    def pages(self) -> list[Page]:
        return list(self._pages)

    def current(self, snapshot: Snapshot, now: float) -> Page | None:
        """返回当前应该显示的页面；所有页面都无数据时返回 ``None``。"""
        available = [i for i, p in enumerate(self._pages) if p.primary.get(snapshot) is not None]
        if not available:
            return None

        if self._switched_at is None:
            self._switched_at = now
            self._index = available[0]
        elif self._index not in available:
            # 当前页的数据源掉了，立刻换到下一个能用的
            self._index = self._next_available(available)
            self._switched_at = now
        elif now - self._switched_at >= self._dwell:
            self._index = self._next_available(available)
            self._switched_at = now
        return self._pages[self._index]

    def _next_available(self, available: list[int]) -> int:
        total = len(self._pages)
        for step in range(1, total + 1):
            candidate = (self._index + step) % total
            if candidate in available:
                return candidate
        return self._index


def preview_rotation(
    pages: Sequence[Page], snapshot: Snapshot, *, ble: bool = True
) -> list[tuple[Page, Lcd03Frame]]:
    """按顺序渲染每一页，供 ``preview`` 子命令在终端里画出来。"""
    return [(page, render_lcd(page, snapshot, ble=ble)) for page in pages]
