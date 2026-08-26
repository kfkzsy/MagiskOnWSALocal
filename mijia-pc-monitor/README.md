# mijia-pc-monitor

把米家蓝牙温湿度计（LYWSD03MMC）改造成 **PC 性能监视器**：通过蓝牙把
CPU 和 GPU 的**占用率、功耗、温度**推送到它的段码屏上轮播显示。

```
── CPU 温度: 72.5 °C            ── GPU 功耗: 241 W
   _   _   _                       _
    |  _| |_                       _| |_|   |
    | |_ . _|                     |_    |   |
         _                                 _   _
        |   |_                            |   |_|
        |_  |_                            |_| |
  BLE  (^_^)  °C                    BLE  (ooo)
```

小号数字区被用来写两个字母的**标签**，一眼能看出当前显示的是哪项指标：

| 标签 | 含义 | 标签 | 含义 |
| --- | --- | --- | --- |
| `Cu` | CPU 占用率 | `Gu` | GPU 占用率 |
| `CP` | CPU 功耗 | `GP` | GPU 功耗 |
| `Ct` | CPU 温度 | `Gt` | GPU 温度 |

笑脸图标同时反映当前部件的负载：`(^_^)` 轻载、`(   )` 中载、`(ooo)` 高载。

---

## 一、前提：必须先刷第三方固件

**原厂固件做不到这件事。** 米家原厂固件只会广播自己传感器的温湿度，
没有任何"显示外部数据"的接口。要让屏幕显示 PC 的数据，必须先刷
[pvvx/ATC_MiThermometer](https://github.com/pvvx/ATC_MiThermometer)
自定义固件——它提供了两条本项目依赖的命令：

* `CMD_EXT_DATA (0x22)`：把外部数值交给固件去画；
* `CMD_LCD_DUMP (0x60)`：直接写段码屏显存，于是可以画出固件本身画不出的字母标签。

### 刷固件步骤

1. 用 **Chrome / Edge**（需要 Web Bluetooth，Firefox 和 Safari 不行）打开
   [TelinkMiFlasher.html](https://pvvx.github.io/ATC_MiThermometer/TelinkMiFlasher.html)；
2. 点 **Connect**，选中你的 `LYWSD03MMC`；
3. 点 **Do Activation** 获取 bindkey（首次必须做，否则刷完设备会变砖）；
4. 选 `ATC_v??_LYWSD03MMC.bin`，点 **Start Flashing**，等进度走完；
5. 刷完设备广播名会变成 `ATC_xxxxxx`，说明成功了。

> 刷机有变砖风险，且会让设备脱离米家 App。开始之前请确认你能接受这一点。

固件设置里**不要开启 PinCode**，本程序不处理配对码；另外确认 `Connect`
选项没被关掉，否则设备不接受连接。

### 支持的型号

`lcd` 模式（带文字标签）是按 LYWSD03MMC 的 6 字节显存布局写死的，只适用于该型号。
pvvx 支持的其它带屏型号（MHO-C401、CGG1、MJWSD05MMC 等）显存布局不同，
程序会自动探测并退回到 `ext` 模式——数值照常显示，只是没有文字标签。

---

## 二、安装

需要 Python 3.11 及以上（配置文件用了标准库的 `tomllib`）。

```bash
cd mijia-pc-monitor
pip install .

# NVIDIA 显卡建议装上 NVML 绑定（没有则回退到调用 nvidia-smi）
pip install ".[nvidia]"

# Windows 还需要
pip install ".[windows]"
```

也可以不安装，直接在本目录用 `python -m mijia_pc_monitor` 运行。

---

## 三、使用

```bash
# 1. 找到设备
mijia-pc-monitor scan

# 2. 跑起来
mijia-pc-monitor run -a A4:C1:38:00:11:22

# 不带 -a 也行，会自动扫描并连信号最强的一台
mijia-pc-monitor run
```

按 `Ctrl-C` 退出，程序会把屏幕交还给固件，恢复显示温湿度。

另外两个不需要蓝牙设备的子命令，用来排查问题：

```bash
mijia-pc-monitor preview   # 在终端里画出每一页的效果
mijia-pc-monitor metrics   # 打印一次采样结果（JSON），确认各数据源是否可用
```

常用参数：

```bash
mijia-pc-monitor run --pages cpu_temp gpu_temp   # 只看两个温度
mijia-pc-monitor run --interval 3 --dwell 5      # 3 秒刷新一次，每页停 5 秒
mijia-pc-monitor run --mode ext                  # 强制用兼容模式
mijia-pc-monitor -v run                          # 调试日志
```

配置文件见 [`config.example.toml`](config.example.toml)，复制到
`~/.config/mijia-pc-monitor/config.toml` 后按注释改即可。命令行参数优先级高于配置文件。

---

## 四、数据从哪来

| 指标 | Linux | Windows |
| --- | --- | --- |
| CPU 占用率 | `psutil` | `psutil` |
| CPU 温度 | `psutil` 读 `coretemp` / `k10temp` 等 | LibreHardwareMonitor |
| CPU 功耗 | RAPL（`/sys/class/powercap/.../energy_uj`） | LibreHardwareMonitor |
| GPU 全部 | NVML → `nvidia-smi` → DRM sysfs（AMD） | NVML → `nvidia-smi` → LibreHardwareMonitor |

取不到的指标不会显示成 0，对应的页面会**直接从轮播里跳过**。先跑一次
`mijia-pc-monitor metrics` 就能看到哪些数据源可用。

### Linux：CPU 功耗需要放开 RAPL 权限

内核 5.10 起 `energy_uj` 默认只有 root 可读（CVE-2020-8694：能量读数可被用于
侧信道推断）。桌面机上可以装一条 udev 规则放开：

```bash
sudo cp packaging/99-powercap-rapl.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
```

介意这个风险就别装——程序会自动降级，只是不显示 CPU 功耗。

### Windows：需要 LibreHardwareMonitor

Windows 没有可以直接读的温度/功耗接口。请下载
[LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor)，
**以管理员身份运行**，并在 Options 里勾选 **WMI Provider**，然后保持它在后台开着。
本程序通过 WMI 读它发布的传感器数据（老版 OpenHardwareMonitor 也兼容）。

### AMD 显卡（Linux）

走 `amdgpu` 的 sysfs 节点：占用率读 `gpu_busy_percent`，功耗和温度读对应的
hwmon 节点，无需额外配置。

---

## 五、后台常驻

**Linux（systemd 用户级服务）**

```bash
mkdir -p ~/.config/systemd/user
cp packaging/mijia-pc-monitor.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now mijia-pc-monitor
journalctl --user -u mijia-pc-monitor -f
```

**Windows**：用「任务计划程序」创建一个登录时触发的任务，操作填
`pythonw.exe -m mijia_pc_monitor run`（用 `pythonw` 可以不弹黑框）。

---

## 六、常见问题

**扫不到设备**
先确认刷完固件后广播名变成了 `ATC_xxxxxx`。改过名字的话用
`mijia-pc-monitor scan --all` 列出所有 BLE 设备，或者在配置里改 `name_prefix`。

**连上了但屏幕没反应**
多半是显示模式不对。看日志里那行"显存 N 字节 → 使用 X 模式"：不是 6 字节
就说明不是 LYWSD03MMC，应该用 `--mode ext`。

**屏幕在数据和温湿度之间来回闪**
`ext` 模式下外部数据有有效期，过期就会闪回自身读数。程序默认把有效期设为
刷新周期的 4 倍，如果你把 `interval` 调得很大，同时又改动过代码，注意保持这个关系。

**总是断线重连**
温湿度计用的是纽扣电池，BLE 连接本来就比较脆弱。程序会自动指数退避重连
（2 秒起，最多 30 秒）。离得太远、电池快没电、或者电脑蓝牙同时连了太多设备
都会加剧这个问题。

**耗电会明显变快吗**
会。保持 BLE 连接并持续刷屏比原本只广播费电得多，一颗 CR2032 大概能撑几周
而不是原来的一年多。把 `interval` 调大能缓解一些。

**能显示内存占用 / 硬盘温度吗**
目前只做了题目要求的 6 项。加新指标的话：在
[`mijia_pc_monitor/metrics/`](mijia_pc_monitor/metrics/) 里加采集，
再到 [`render.py`](mijia_pc_monitor/render.py) 的 `PAGES` 里加一页即可。

---

## 七、实现说明

```
mijia_pc_monitor/
├── device/
│   ├── protocol.py   pvvx 固件的 BLE 命令编码（纯函数）
│   ├── lcd.py        LYWSD03MMC 6 字节显存的段码渲染
│   └── client.py     bleak 连接、请求/应答、断线处理
├── metrics/          CPU / GPU 各平台数据源
├── render.py         指标 → 页面的编排，两种显示模式
├── app.py            刷新循环与重连
└── cli.py            命令行入口
```

协议部分不是猜的，是对着固件源码写的：命令号见
[`cmd_parser.h`](https://github.com/pvvx/ATC_MiThermometer/blob/master/src/cmd_parser.h)，
`external_data_t` 结构见
[`app.h`](https://github.com/pvvx/ATC_MiThermometer/blob/master/src/app.h)，
段码位图见
[`lcd_lywsd03mmc.c`](https://github.com/pvvx/ATC_MiThermometer/blob/master/src/lcd_lywsd03mmc.c)
开头的注释图。字库与固件的 `display_numbers[]` 逐字节一致，并有测试守着。

跑测试（不需要蓝牙设备，也不需要第三方包）：

```bash
python -m unittest discover -s tests -t .
```

## 致谢

* [pvvx/ATC_MiThermometer](https://github.com/pvvx/ATC_MiThermometer) —— 自定义固件
* [hbldh/bleak](https://github.com/hbldh/bleak) —— 跨平台 BLE 库
