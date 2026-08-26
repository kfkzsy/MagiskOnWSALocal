"""刷新循环：采样 → 渲染 → 推送到屏幕，断线自动重连。"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import time

from .config import MODE_AUTO, MODE_EXT, MODE_LCD, AppConfig
from .device.client import DeviceError, MijiaDisplayClient, scan, supports_lcd_mode
from .metrics.collector import MetricsCollector
from .render import PageRotator, format_page, render_ext, render_lcd, resolve_pages

log = logging.getLogger(__name__)

#: 重连退避的起始与上限（秒）
INITIAL_BACKOFF = 2.0
MAX_BACKOFF = 30.0


class MonitorApp:
    """把指标持续推送到温湿度计屏幕上。"""

    def __init__(self, config: AppConfig) -> None:
        self.config = config
        self.collector = MetricsCollector()
        self._rotator = PageRotator(
            resolve_pages(config.display.pages), config.display.dwell
        )

    async def run(self, stop: asyncio.Event) -> int:
        """一直跑到 ``stop`` 被置位；返回进程退出码。"""
        for line in self.collector.describe():
            log.info("%s", line)

        address = self.config.device.address
        if not address:
            address = await self._autodetect_address()
            if address is None:
                return 1

        backoff = INITIAL_BACKOFF
        while not stop.is_set():
            client = MijiaDisplayClient(
                address,
                adapter=self.config.device.adapter,
                connect_timeout=self.config.device.connect_timeout,
            )
            try:
                await client.connect()
                backoff = INITIAL_BACKOFF  # 连上了就把退避重置
                mode = await self._resolve_mode(client)
                await self._refresh_loop(client, mode, stop)
            except DeviceError as exc:
                log.error("%s", exc)
            except asyncio.CancelledError:
                raise
            finally:
                with contextlib.suppress(Exception):
                    await client.restore()
                await client.disconnect()

            if stop.is_set():
                break
            log.info("%.0f 秒后重连……", backoff)
            await _sleep_or_stop(stop, backoff)
            backoff = min(backoff * 2, MAX_BACKOFF)
        return 0

    # ------------------------------------------------------------------ ---
    async def _autodetect_address(self) -> str | None:
        log.info("未配置设备地址，开始扫描……")
        devices = await scan(
            timeout=self.config.device.scan_timeout,
            adapter=self.config.device.adapter,
            name_prefix=self.config.device.name_prefix,
        )
        if not devices:
            log.error(
                "没有扫到名字以 %r 开头的设备。先用 `mijia-pc-monitor scan` 看看，"
                "或者在配置里直接写死 address。",
                self.config.device.name_prefix,
            )
            return None
        chosen = devices[0]
        log.info("自动选中信号最强的设备：%s", chosen)
        if len(devices) > 1:
            log.info("附近还有 %d 台，建议把 address 写进配置以免选错", len(devices) - 1)
        return chosen.address

    async def _resolve_mode(self, client: MijiaDisplayClient) -> str:
        configured = self.config.display.mode
        buffer_size = await client.detect_lcd_buffer_size()
        if configured == MODE_AUTO:
            mode = MODE_LCD if supports_lcd_mode(buffer_size) else MODE_EXT
            log.info(
                "显存 %s 字节 → 使用 %s 模式",
                buffer_size if buffer_size is not None else "未知",
                mode,
            )
            return mode
        if configured == MODE_LCD and not supports_lcd_mode(buffer_size):
            log.warning(
                "配置强制使用 lcd 模式，但设备显存是 %s 字节（LYWSD03MMC 应为 6），"
                "显示可能是乱的；出问题请改成 mode = \"ext\"",
                buffer_size if buffer_size is not None else "未知",
            )
        return configured

    async def _refresh_loop(
        self, client: MijiaDisplayClient, mode: str, stop: asyncio.Event
    ) -> None:
        display = self.config.display
        loop = asyncio.get_running_loop()
        while not stop.is_set() and client.connected:
            snapshot = await loop.run_in_executor(None, self.collector.read)
            page = self._rotator.current(snapshot, time.monotonic())
            if page is None:
                log.warning("所有指标都取不到，跳过这一轮刷新")
            else:
                log.debug("%s", format_page(page, snapshot))
                if mode == MODE_LCD:
                    frame = render_lcd(page, snapshot, ble=display.show_ble_icon)
                    await client.show_lcd(frame)
                else:
                    await client.show_ext(
                        render_ext(page, snapshot, hold_seconds=display.hold_seconds())
                    )
            await _sleep_or_stop(stop, display.interval, client.disconnected_event)


async def _sleep_or_stop(stop: asyncio.Event, seconds: float, *extra: asyncio.Event) -> None:
    """睡 ``seconds`` 秒，但任何一个事件被置位就提前醒。"""
    waiters = [asyncio.ensure_future(event.wait()) for event in (stop, *extra)]
    try:
        await asyncio.wait(waiters, timeout=seconds, return_when=asyncio.FIRST_COMPLETED)
    finally:
        for waiter in waiters:
            waiter.cancel()
        await asyncio.gather(*waiters, return_exceptions=True)
