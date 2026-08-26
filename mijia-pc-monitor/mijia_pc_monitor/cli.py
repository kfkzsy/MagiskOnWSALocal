"""命令行入口。"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import json
import logging
import signal
import sys

from . import __version__
from .app import MonitorApp
from .config import MODES, apply_overrides, load_config
from .device.client import DeviceError, scan
from .metrics.collector import MetricsCollector
from .render import PAGES, format_page, preview_rotation, resolve_pages

log = logging.getLogger("mijia_pc_monitor")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="mijia-pc-monitor",
        description="把米家蓝牙温湿度计 (LYWSD03MMC) 变成 PC 性能监视器",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "可用页面：\n  "
            + "\n  ".join(f"{key:<10} {page.title}" for key, page in PAGES.items())
        ),
    )
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    parser.add_argument("-c", "--config", help="配置文件路径")
    parser.add_argument(
        "-v", "--verbose", action="store_true", help="输出调试日志（等价于 --log-level DEBUG）"
    )
    parser.add_argument("--log-level", help="日志级别，默认 INFO")

    sub = parser.add_subparsers(dest="command", required=True)

    scan_parser = sub.add_parser("scan", help="扫描附近的温湿度计")
    scan_parser.add_argument("--adapter", help="指定蓝牙适配器，例如 hci1")
    scan_parser.add_argument("--timeout", type=float, help="扫描时长（秒）")
    scan_parser.add_argument(
        "--all", action="store_true", help="不按名字过滤，列出所有 BLE 设备"
    )

    run_parser = sub.add_parser("run", help="持续把性能数据推送到屏幕")
    run_parser.add_argument("-a", "--address", help="设备 MAC 地址（macOS 上是 UUID）")
    run_parser.add_argument("--adapter", help="指定蓝牙适配器，例如 hci1")
    run_parser.add_argument("--mode", choices=MODES, help="显示模式，默认 auto")
    run_parser.add_argument(
        "--pages", nargs="+", metavar="PAGE", help="轮播的页面，按给定顺序"
    )
    run_parser.add_argument("--interval", type=float, help="刷新周期（秒）")
    run_parser.add_argument("--dwell", type=float, help="每页停留时长（秒）")

    preview_parser = sub.add_parser(
        "preview", help="在终端里画出每一页的效果，不需要蓝牙设备"
    )
    preview_parser.add_argument("--pages", nargs="+", metavar="PAGE", help="要预览的页面")

    sub.add_parser("metrics", help="打印一次采样结果（JSON），用于排查数据源")

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    try:
        config = load_config(args.config)
        config = apply_overrides(
            config,
            address=getattr(args, "address", None),
            adapter=getattr(args, "adapter", None),
            mode=getattr(args, "mode", None),
            pages=getattr(args, "pages", None),
            interval=getattr(args, "interval", None),
            dwell=getattr(args, "dwell", None),
            scan_timeout=getattr(args, "timeout", None),
            log_level="DEBUG" if args.verbose else args.log_level,
        )
    except (ValueError, FileNotFoundError) as exc:
        parser.error(str(exc))

    logging.basicConfig(
        level=getattr(logging, config.log_level, logging.INFO),
        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
        datefmt="%H:%M:%S",
    )

    handlers = {
        "scan": lambda: asyncio.run(_cmd_scan(config, show_all=args.all)),
        "run": lambda: asyncio.run(_cmd_run(config)),
        "preview": lambda: _cmd_preview(config),
        "metrics": lambda: _cmd_metrics(),
    }
    try:
        return handlers[args.command]()
    except DeviceError as exc:
        log.error("%s", exc)
        return 1
    except KeyboardInterrupt:
        return 130


async def _cmd_scan(config, *, show_all: bool) -> int:
    prefix = None if show_all else config.device.name_prefix
    print(f"扫描中（{config.device.scan_timeout:.0f} 秒）……")
    devices = await scan(
        timeout=config.device.scan_timeout,
        adapter=config.device.adapter,
        name_prefix=prefix,
    )
    if not devices:
        print("什么都没扫到。")
        if not show_all:
            print("试试 `mijia-pc-monitor scan --all` 看看是不是广播名被改过。")
        return 1
    print(f"找到 {len(devices)} 台：")
    for device in devices:
        print(f"  {device}")
    print("\n把地址填进配置文件的 [device] address，或者用 run -a <地址>。")
    return 0


async def _cmd_run(config) -> int:
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for signal_name in ("SIGINT", "SIGTERM"):
        sig = getattr(signal, signal_name, None)
        if sig is None:
            continue
        # Windows 的 ProactorEventLoop 不支持 add_signal_handler
        with contextlib.suppress(NotImplementedError):
            loop.add_signal_handler(sig, stop.set)

    app = MonitorApp(config)
    try:
        return await app.run(stop)
    except KeyboardInterrupt:
        stop.set()
        return 130


def _cmd_preview(config) -> int:
    collector = MetricsCollector()
    for line in collector.describe():
        print(line)
    collector.read()  # 先打一次底，CPU 占用率才有意义
    snapshot = collector.read()
    print()
    pages = resolve_pages(config.display.pages)
    for page, frame in preview_rotation(pages, snapshot):
        print(f"── {format_page(page, snapshot)}   [显存 {frame.to_bytes().hex(' ')}]")
        print(frame.render_ascii())
        print()
    print(f"每页停留 {config.display.dwell:.0f} 秒，刷新周期 {config.display.interval:.0f} 秒。")
    return 0


def _cmd_metrics() -> int:
    collector = MetricsCollector()
    for line in collector.describe():
        print(line, file=sys.stderr)
    collector.read()
    snapshot = collector.read()
    print(json.dumps(snapshot.as_dict(), indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
