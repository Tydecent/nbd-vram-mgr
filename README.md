# NBD-VRAM 管理脚本

在 Linux 上把 NVIDIA GPU 的 VRAM 暂时作为高优先级 swap 使用。本仓库以交互式管理脚本 `mgr.sh` 包装了 [nbd-vram](nbd-vram/README.md) 子项目：负责环境检查、安装、配置、systemd 管理、状态查看、更新和卸载。

> **风险提示**：VRAM swap 会占用显存并改变内存压力下的数据流向。仅建议在 systemd + NVIDIA 官方驱动环境中使用；原生 Windows 或无 NVIDIA 驱动的环境不受支持。分配显存时请为桌面和 GPU 负载保留余量。

## 工作原理

`nbd-vram` daemon 使用 CUDA 将一块 VRAM 暴露为 Unix socket 上的 NBD 设备，再由 Linux NBD 驱动挂载为 `/dev/nbdX`，最后通过 `swapon` 作为交换分区使用。

```text
内核 swap ─ /dev/nbdX ─ NBD 驱动 ─ Unix socket ─ nbd-vram ─ CUDA ─ GPU VRAM
```

不需要自编写内核模块；daemon 由系统包装为 systemd 服务运行。

## 环境要求

- Linux，启用 systemd 和内核 NBD 支持
- NVIDIA 官方驱动及可用的 `libcuda.so.1`
- NVIDIA GPU（支持 CUDA）
- `nbd-client`
- `gcc`、`make`
- 管理命令需要管理员权限；脚本会在需要时通过 `sudo` 重新执行

脚本不会自动安装 NVIDIA 驱动、禁用 Nouveau 或修改 GRUB。缺少依赖时会提示各发行版的安装命令。

## 获取与安装

克隆主仓库及内置子模块：

```bash
git clone --recurse-submodules https://github.com/Tydecent/nbd-vram-mgr.git
cd nbd-vram-mgr

# 如果克隆时没有递归初始化子模块，也可执行：
git submodule update --init --recursive
```

交互安装：

```bash
./mgr.sh install
```

脚本会检查环境和子模块，调用内层安装流程，并通过 systemd drop-in 写入显存大小和 swap 优先级。未指定参数时，交互模式会建议显存大小；非交互模式使用 GPU 总显存的 80%，向下取整到 512 MiB。

指定显存和优先级：

```bash
sudo ./mgr.sh install --size 7.5 --priority 1500 --yes
```

其中 `7.5` 表示约 7680 MiB；优先级越大越先使用，范围是 `0-32767`。

先预览将执行的操作：

```bash
./mgr.sh install --size 7 --dry-run
```

## 日常命令

| 命令 | 作用 |
|---|---|
| `./mgr.sh` 或 `./mgr.sh menu` | 中文交互菜单 |
| `./mgr.sh install [--size GB] [--priority N] [--yes] [--dry-run]` | 安装或幂等重新配置 |
| `./mgr.sh config [--size GB] [--priority N] [--yes] [--dry-run]` | 修改已保存的配置并重启 |
| `./mgr.sh start` | 启动 VRAM swap 服务 |
| `./mgr.sh stop [--yes]` | 停止服务（默认需要确认） |
| `./mgr.sh restart [--yes]` | 重启服务 |
| `./mgr.sh status` | 查看服务、swap、显存和近期日志 |
| `./mgr.sh logs` | 查看 service 最近 200 条日志 |
| `./mgr.sh update [--yes] [--remote]` | 更新子模块；`--remote` 拉取子模块远端版本 |
| `./mgr.sh uninstall [--yes] [--dry-run]` | 卸载本工具及子项目安装的组件 |
| `./mgr.sh help` | 查看完整内置帮助 |

示例：

```bash
./mgr.sh status
./mgr.sh config --size 6 --priority 1500 --yes
./mgr.sh restart --yes
```

## 配置文件

管理脚本保存配置：

```text
/etc/nbd-vram-mgr.conf
```

运行时参数通过 systemd drop-in 下发，不直接改写子模块的 service 模板：

```text
/etc/systemd/system/vram-swap-nbd.service.d/override.conf
```

主要环境变量来自 `nbd-vram`：

```ini
VRAM_SETUP_SIZE_MB=7168
VRAM_SWAP_PRIORITY=1500
VRAM_NBD_THREADS=8
VRAM_NBD_CONNECTIONS=8
```

线程和连接数由内层安装脚本设为 `nproc`。电源管理配置位于：

```text
/etc/nbd-vram.conf
```

修改配置后可直接使用 `./mgr.sh config`；也可手动执行：

```bash
sudo systemctl daemon-reload
sudo systemctl restart vram-swap-nbd
```

## 验证与日志

确认 swap 已启用：

```bash
swapon --show
systemctl status vram-swap-nbd
nvidia-smi
```

查看 daemon 日志：

```bash
journalctl -u vram-swap-nbd -n 200 --no-pager
./mgr.sh logs
```

管理脚本日志位于：

```text
/var/log/nbd-vram-mgr.log
```

退出码：`0` 成功，`1` 通用错误，`2` 环境不满足，`3` 权限不足，`4` 子模块问题，`5` 安装或服务操作失败。

## 更新

只同步已锁定的子模块版本：

```bash
./mgr.sh update --yes
```

同步并拉取子模块远端最新提交：

```bash
./mgr.sh update --remote --yes
```

更新后脚本会询问是否重新安装。更新子模块可能改变内层实现或配置约定，请先检查状态并验证 swap。

## 卸载

交互卸载：

```bash
sudo ./mgr.sh uninstall
```

非交互卸载：

```bash
sudo ./mgr.sh uninstall --yes
```

卸载只清理本工具创建的 drop-in 和管理配置，并调用子模块卸载流程。不会删除 `nbd-vram/` 子模块目录，也不会关闭管理范围之外的其他 swap。

## 使用注意

- 停止 VRAM swap 时，务必通过 service 或本脚本停止，而不是直接终止 daemon，以免页面无法安全回收。
- 高显存占用会影响桌面、游戏、CUDA 和其他 GPU 工作负载；需要重度使用 GPU 时先减小分配或停止服务。
- 系统休眠前，内置 suspend service 会优先清理 VRAM swap。内存严重不足时 `swapoff` 可能失败，不要强制维持休眠状态。
- 分配的大小只是上限；GPU 显存不足时 daemon 会按步骤回退。
- 本仓库不关闭或卸载未由本工具管理的 swap 设备。

## 子项目

实际 daemon、基准测试和底层说明位于 [nbd-vram](nbd-vram/README.md)。其原始文档包含架构、并发、性能、安全机制和硬件测试详情。

仓库结构：

```text
mgr.sh          顶层管理入口
nbd-vram/       NBD-VRAM daemon 与 systemd 安装资源
nbd-vram/README.md
nbd-vram/LICENSE
```

## 法律与许可

子项目许可证见 [nbd-vram/LICENSE](nbd-vram/LICENSE)。