"""把米家蓝牙温湿度计 (LYWSD03MMC) 改造成 PC 性能监视器。

需要设备刷入 pvvx 的 ATC_MiThermometer 自定义固件，本程序通过 BLE
把 CPU / GPU 的占用率、功耗、温度推送到温湿度计的段码屏上显示。
"""

__version__ = "1.0.0"

__all__ = ["__version__"]
