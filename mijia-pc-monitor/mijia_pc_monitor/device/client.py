"""与温湿度计的 BLE 连接。

pvvx 固件把所有命令都收敛到一个特征值上（``0x1F1F``，Write + Notify），
命令的应答会以同样的命令号 Notify 回来，所以这里做了一个简单的
"写一条、等对应命令号的应答"的请求/应答封装。

``bleak`` 只在真正需要连接时才导入，这样纯逻辑部分（协议、渲染）可以在
没装蓝牙依赖的机器上跑测试。
"""

from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass

from . import protocol
from .lcd import LCD_BUFFER_SIZE, Lcd03Frame

log = logging.getLogger(__name__)

#: 等待命令应答的超时（秒）
RESPONSE_TIMEOUT = 5.0


class DeviceError(RuntimeError):
    """连接或通讯失败。"""


@dataclass(frozen=True)
class DiscoveredDevice:
    address: str
    name: str | None
    rssi: int | None

    def __str__(self) -> str:
        rssi = "?" if self.rssi is None else f"{self.rssi} dBm"
        return f"{self.address}  {self.name or '(无名)'}  {rssi}"


def _adapter_kwargs(adapter: str | None) -> dict:
    """指定适配器（如 ``hci1``）。

    bleak 3.x 起顶层的 ``adapter=`` 参数已废弃，改为 BlueZ 专属的
    ``bluez={"adapter": ...}``；非 Linux 平台该参数会被后端忽略。
    """
    return {"bluez": {"adapter": adapter}} if adapter else {}


def _import_bleak():
    try:
        import bleak  # type: ignore[import-not-found]
    except ImportError as exc:  # pragma: no cover - 取决于运行环境
        raise DeviceError(
            "需要 bleak 才能使用蓝牙功能，请先执行：pip install bleak"
        ) from exc
    return bleak


async def scan(
    timeout: float = 8.0,
    adapter: str | None = None,
    name_prefix: str | None = None,
) -> list[DiscoveredDevice]:
    """扫描附近的设备。

    刷了 pvvx 固件的设备默认广播名是 ``ATC_xxxxxx``，同时会广播
    Environmental Sensing（``0x181A``）服务数据；两个条件命中其一就算。
    """
    bleak = _import_bleak()
    try:
        found = await bleak.BleakScanner.discover(
            timeout=timeout, return_adv=True, **_adapter_kwargs(adapter)
        )
    except Exception as exc:  # noqa: BLE001 - 各平台后端异常不统一
        raise DeviceError(
            f"扫描失败：{exc}。请确认蓝牙适配器已启用"
            "（Linux 上检查 bluetooth 服务是否在运行、当前用户是否有权限）。"
        ) from exc

    devices: list[DiscoveredDevice] = []
    for device, adv in found.values():
        name = adv.local_name or device.name
        matches_name = bool(name and name_prefix and name.upper().startswith(name_prefix.upper()))
        matches_service = any(
            uuid.lower().startswith("0000181a") for uuid in (adv.service_data or {})
        )
        if name_prefix and not (matches_name or matches_service):
            continue
        devices.append(DiscoveredDevice(device.address, name, adv.rssi))
    devices.sort(key=lambda d: (d.rssi is None, -(d.rssi or 0)))
    return devices


class MijiaDisplayClient:
    """连接一台刷了 pvvx 固件的温湿度计，并把内容推到它的屏幕上。"""

    def __init__(
        self,
        address: str,
        *,
        adapter: str | None = None,
        connect_timeout: float = 20.0,
    ) -> None:
        self.address = address
        self._adapter = adapter
        self._connect_timeout = connect_timeout
        self._client = None
        self._pending: dict[int, asyncio.Future[bytes]] = {}
        self._disconnected = asyncio.Event()
        self._took_over_lcd = False

    # ------------------------------------------------------------ 连接管理 ----
    @property
    def connected(self) -> bool:
        return self._client is not None and self._client.is_connected

    @property
    def disconnected_event(self) -> asyncio.Event:
        return self._disconnected

    async def connect(self) -> None:
        bleak = _import_bleak()
        self._disconnected.clear()
        client = bleak.BleakClient(
            self.address,
            disconnected_callback=self._on_disconnect,
            timeout=self._connect_timeout,
            **_adapter_kwargs(self._adapter),
        )
        try:
            await client.connect()
            await client.start_notify(protocol.CHAR_UUID, self._on_notify)
        except Exception as exc:  # noqa: BLE001 - bleak 各平台后端异常不统一
            with_hint = (
                f"连接 {self.address} 失败：{exc}。"
                "请确认设备已刷 pvvx 自定义固件、在有效范围内，"
                "且固件里没有开启 PinCode。"
            )
            raise DeviceError(with_hint) from exc
        self._client = client
        log.info("已连接 %s", self.address)

    async def disconnect(self) -> None:
        client, self._client = self._client, None
        self._cancel_pending(DeviceError("连接已断开"))
        if client is None:
            return
        try:
            await client.disconnect()
        except Exception as exc:  # noqa: BLE001
            log.debug("断开连接时出错（可忽略）：%s", exc)

    def _on_disconnect(self, _client) -> None:
        log.warning("设备 %s 断开了连接", self.address)
        self._disconnected.set()
        self._cancel_pending(DeviceError("连接已断开"))

    def _cancel_pending(self, error: Exception) -> None:
        for future in self._pending.values():
            if not future.done():
                future.set_exception(error)
        self._pending.clear()

    def _on_notify(self, _characteristic, data: bytearray) -> None:
        if not data:
            return
        future = self._pending.pop(data[0], None)
        if future is not None and not future.done():
            future.set_result(bytes(data))

    # -------------------------------------------------------------- 收发 ----
    async def write(self, payload: bytes) -> None:
        if self._client is None:
            raise DeviceError("尚未连接")
        try:
            await self._client.write_gatt_char(protocol.CHAR_UUID, payload, response=True)
        except Exception as exc:  # noqa: BLE001
            raise DeviceError(f"写入失败：{exc}") from exc

    async def request(self, payload: bytes, timeout: float = RESPONSE_TIMEOUT) -> bytes:
        """写一条命令并等待同命令号的 Notify 应答。"""
        command = payload[0]
        loop = asyncio.get_running_loop()
        future: asyncio.Future[bytes] = loop.create_future()
        self._pending[command] = future
        try:
            await self.write(payload)
            return await asyncio.wait_for(future, timeout)
        except asyncio.TimeoutError as exc:
            raise DeviceError(f"命令 0x{command:02X} 超时未应答") from exc
        finally:
            self._pending.pop(command, None)

    # -------------------------------------------------------------- 显示 ----
    async def detect_lcd_buffer_size(self) -> int | None:
        """探测显存大小，用来判断能不能用 ``lcd`` 模式。

        对空负载的 ``CMD_LCD_DUMP``，固件会把当前显存原样 Notify 回来，
        长度就是该型号的显存大小（LYWSD03MMC 是 6 字节）。
        """
        try:
            response = await self.request(protocol.encode_lcd_query())
        except DeviceError as exc:
            log.debug("显存探测失败：%s", exc)
            return None
        size = len(response) - 1
        return size if size > 0 else None

    async def show_lcd(self, frame: Lcd03Frame) -> None:
        await self.write(protocol.encode_lcd_dump(frame.to_bytes()))
        self._took_over_lcd = True

    async def show_ext(self, payload: bytes) -> None:
        await self.write(payload)

    async def restore(self) -> None:
        """把屏幕交还给固件，恢复显示温湿度。

        退出时尽量执行，但绝不能因为它失败而影响退出流程——设备断连后
        固件本来也会自己清掉接管标志。
        """
        try:
            if self._took_over_lcd:
                await self.write(protocol.encode_lcd_release())
                self._took_over_lcd = False
            await self.write(protocol.encode_ext_data_release())
        except DeviceError as exc:
            log.debug("恢复默认显示失败（断连后固件会自行恢复）：%s", exc)

    async def __aenter__(self) -> "MijiaDisplayClient":
        await self.connect()
        return self

    async def __aexit__(self, *_exc_info) -> None:
        await self.restore()
        await self.disconnect()


def supports_lcd_mode(buffer_size: int | None) -> bool:
    """只有显存正好 6 字节的型号（LYWSD03MMC）才认得我们画的段码。"""
    return buffer_size == LCD_BUFFER_SIZE
