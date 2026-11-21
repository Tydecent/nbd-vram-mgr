#!/usr/bin/env bash
#
# mgr.sh —— NBD-VRAM 管理脚本（安装 / 配置 / 启动 / 停止 / 状态 / 日志 / 更新 / 卸载）
#
# 适用场景：
#   - Linux + systemd + NVIDIA 官方驱动 + 内核支持 nbd 的笔记本/台式机；
#   - 不适用于原生 Windows；
#   - 显存 swap 的延迟高于内存（微秒级，仍远快于 NVMe），适合承载冷数据。
#
# 设计边界：
#   - 不修改子模块 nbd-vram/ 内的任何文件；对服务配置的覆盖一律通过 systemd
#     drop-in（/etc/systemd/system/<service>.service.d/override.conf）完成。
#   - 不自动安装 NVIDIA 驱动、不自动禁用 Nouveau、不自动修改 GRUB、
#     不自动安装缺少的依赖（只给出 Debian/Ubuntu、Fedora、Arch 的提示命令）。
#   - 卸载只清理本工具创建的内容（drop-in、/etc/nbd-vram-mgr.conf）以及子模块
#     uninstall.sh 声明的组件；不删除 nbd-vram/ 子模块目录，不关闭其他 swap。
#
# 关键事实依据（已阅读子模块源码逐一确认；若子模块升级请同步核对）：
#   - 服务名：vram-swap-nbd.service
#       依据 nbd-vram/install.sh:165 `systemctl enable vram-swap-nbd.service`
#       及模板 nbd-vram/systemd/vram-swap-nbd.service；
#       本脚本用 detect_service_name_from_repo() 动态核对，找不到时回退该默认值。
#   - 环境变量：VRAM_SETUP_SIZE_MB（模板第 15 行）、VRAM_SWAP_PRIORITY（第 16 行）
#       依据 nbd-vram/systemd/vram-swap-nbd.service；
#       nbd-vram-connect.sh 第 37 行以 `swapon "$NBD_DEV" -p "${VRAM_SWAP_PRIORITY:-1500}"`
#       使用优先级。变量名与需求默认值一致，若子模块变更，verify_submodule_facts()
#       会在安装时给出警告。
#   - 设备名：动态选取首个空闲 /dev/nbd0..15，记录于 /run/nbd-vram-dev
#       依据 nbd-vram/nbd-vram-connect.sh；
#       本脚本验证 swap 时只匹配 ^/dev/nbd[0-9]+$，不会误判其他 swap。
#   - 安装方式：nbd-vram/install.sh（含交互提示；本脚本以 </dev/null 非交互调用，
#       其“电源管理”询问取默认值，其 --size 询问被跳过，显存大小由本脚本的
#       drop-in 覆盖，不直接修改子模块生成的服务文件）。
#   - 卸载方式：nbd-vram/uninstall.sh（末尾询问是否删除 /etc/nbd-vram.conf，
#       非交互 stdin 下保留该文件，符合“不自动删除用户配置”）。
#   - 附带单元：vram-swap-nbd-suspend.service、nbd-vram-power-check.service、
#       nbd-vram-battery-watch.service/.timer（由子模块 install.sh 安装与启用）。
#   - 默认大小规则：本脚本按需求采用“GPU 总显存 80%，向下取整到 512 MiB 倍数”，
#       与子模块 install.sh 交互提示的“总显存-1GiB/3GiB”建议不同，以本脚本为准。
#
# 退出码：0 成功；1 通用错误；2 环境不满足；3 权限不足；4 子模块问题；5 安装/服务操作失败。

set -Eeuo pipefail

# ------------------------------ 路径与常量 ------------------------------
# 从脚本自身位置解析仓库根目录，支持从任意当前工作目录执行，不硬编码 home 路径。
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$ROOT_DIR/$(basename "${BASH_SOURCE[0]}")"
SUBMODULE_DIR="$ROOT_DIR/nbd-vram"

CONFIG_FILE="/etc/nbd-vram-mgr.conf"
LOG_FILE="/var/log/nbd-vram-mgr.log"
SERVICE_NAME_DEFAULT="vram-swap-nbd"   # 依据 nbd-vram/install.sh:165
ENV_SIZE_VAR="VRAM_SETUP_SIZE_MB"      # 依据 nbd-vram/systemd/vram-swap-nbd.service:15
ENV_PRIO_VAR="VRAM_SWAP_PRIORITY"      # 依据 nbd-vram/systemd/vram-swap-nbd.service:16
DEFAULT_PRIORITY=1500
MIN_SIZE_MB=512

# 由 init_service_name() 填充
SVC_BASE=""
SVC_UNIT=""
DROPIN_DIR=""
DROPIN_PATH=""

# ------------------------------ 运行时状态 ------------------------------
SUBCMD=""
HELP_FLAG=0
ASSUME_YES=0
DRY_RUN=0
OPT_REMOTE=0
SIZE_GB=""        # --size 的原始输入（GB，可小数）
SIZE_MB_OPT=""    # 换算后的 --size（MiB）
RESOLVED_SIZE_MB="" # resolve_size_mb() 解析出的最终大小（MiB）
PRIORITY_OPT=""   # --priority 原始输入
ORIG_ARGS=()
TMP_PATHS=()

# 非 TTY 环境禁用颜色；尊重 NO_COLOR。
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_CYAN=$'\033[36m'
else
    C_RESET=""
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_BLUE=""
    C_CYAN=""
fi

# ------------------------------ 基础工具函数 ------------------------------
info() { printf '%s[信息]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
warn() { printf '%s[警告]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
error() { printf '%s[错误]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
ok() { printf '%s[成功]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }

# 关键操作写入管理日志；无法写入（非 root 等）时静默降级，绝不影响主流程。
log() {
    local msg
    msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    { printf '%s\n' "$msg" >>"$LOG_FILE"; } 2>/dev/null || true
}

# die <退出码> <中文错误信息>
die() {
    local code=$1
    shift
    error "$*"
    log "退出(码=$code): $*"
    exit "$code"
}

# 临时文件：mktemp 创建并登记，退出时统一清理（只用 rm -f 逐个删除，绝不递归删除目录）。
register_tmp() { TMP_PATHS+=("$1"); }

cleanup() {
    local f
    for f in "${TMP_PATHS[@]}"; do
        rm -f "$f" 2>/dev/null || true
    done
}

# ERR 陷阱：输出出错行号（set -E 使其在函数/子 shell 中同样生效）。
on_err() {
    local rc=$1 line=$2
    error "执行出错：第 ${line} 行命令失败（退出码 ${rc}）。请根据上方输出排查。"
    log "错误: 第 ${line} 行退出码 ${rc}"
}
trap 'on_err $? $LINENO' ERR
trap cleanup EXIT

# run_cmd：dry-run 时只打印将执行的关键命令，否则真实执行并记录日志。
run_cmd() {
    if [ "$DRY_RUN" = 1 ]; then
        printf '%s[模拟]%s 将执行: %s\n' "$C_CYAN" "$C_RESET" "$*"
        return 0
    fi
    log "执行: $*"
    "$@"
}

# confirm：危险操作确认；--yes 跳过；dry-run 跳过；非交互环境要求显式 --yes。
confirm() {
    local prompt=$1 reply
    if [ "$ASSUME_YES" = 1 ]; then
        info "已按 --yes 跳过确认: $prompt"
        return 0
    fi
    if [ "$DRY_RUN" = 1 ]; then
        return 0
    fi
    if [ ! -t 0 ]; then
        die 1 "非交互环境需要显式确认，请追加 --yes: $prompt"
    fi
    printf '%s [y/N]: ' "$prompt"
    read -r reply || reply=""
    case "$reply" in
        y | Y | yes | Yes | YES) return 0 ;;
        *) die 1 "已取消，未做任何更改。" ;;
    esac
}

# ask：可选问题的二选一（不终止脚本）；--yes / dry-run / 非交互时返回“否”。
ask() {
    local prompt=$1 reply
    if [ "$ASSUME_YES" = 1 ] || [ "$DRY_RUN" = 1 ] || [ ! -t 0 ]; then
        return 1
    fi
    printf '%s [y/N]: ' "$prompt"
    read -r reply || reply=""
    case "$reply" in
        y | Y | yes | Yes | YES) return 0 ;;
        *) return 1 ;;
    esac
}

# require_root：需要提权的子命令先友好提示，再用 sudo 原样重新执行本脚本（保留参数）。
require_root() {
    if [ "$DRY_RUN" = 1 ]; then
        info "[dry-run] 该操作实际执行时需要 root 权限（当前不提权，仅打印计划）。"
        return 0
    fi
    if [ "$(id -u)" -eq 0 ]; then
        return 0
    fi
    if ! command -v sudo >/dev/null 2>&1; then
        die 3 "权限不足：该操作需要 root，且系统中未找到 sudo。请以 root 运行，例如: sudo $SCRIPT_PATH ${ORIG_ARGS[*]}"
    fi
    if [ -t 0 ] && [ -t 1 ]; then
        info "该操作需要 root 权限，将通过 sudo 重新执行本脚本（可能提示输入密码）..."
        log "通过 sudo 重新执行: sudo $SCRIPT_PATH ${ORIG_ARGS[*]}"
        exec sudo -- "$SCRIPT_PATH" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
    fi
    if sudo -n true 2>/dev/null; then
        info "该操作需要 root 权限，通过免密 sudo 重新执行本脚本..."
        exec sudo -- "$SCRIPT_PATH" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
    fi
    die 3 "权限不足：请以 root 运行或配置免密 sudo，例如: sudo $SCRIPT_PATH ${ORIG_ARGS[*]}"
}

is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

# ------------------------------ 配置读写 ------------------------------
# 从 KEY=VALUE 文件中读取某个键的值（只解析，不 source、不 eval）。
read_kv_file() {
    local file=$1 key=$2 line
    if [ ! -f "$file" ] || [ ! -r "$file" ]; then
        return 0
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "$key="*)
                printf '%s' "${line#"$key="}"
                return 0
                ;;
        esac
    done <"$file"
    return 0
}

# 从 systemd 单元/drop-in 中读取某行 `前缀=值`（如 Environment=VRAM_SETUP_SIZE_MB=）。
read_prefixed_value() {
    local file=$1 prefix=$2 line
    if [ ! -f "$file" ] || [ ! -r "$file" ]; then
        return 0
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "$prefix"*)
                printf '%s' "${line#"$prefix"}"
                return 0
                ;;
        esac
    done <"$file"
    return 0
}

config_get() { read_kv_file "$CONFIG_FILE" "$1"; }

effective_size_mb() {
    local v
    v=$(config_get SIZE_MB)
    if ! is_uint "$v"; then
        v=$(read_prefixed_value "$DROPIN_PATH" "Environment=${ENV_SIZE_VAR}=")
    fi
    if ! is_uint "$v"; then
        v=$(read_prefixed_value "/etc/systemd/system/$SVC_UNIT" "Environment=${ENV_SIZE_VAR}=")
    fi
    printf '%s' "$v"
}

effective_priority() {
    local v
    v=$(config_get PRIORITY)
    if ! is_uint "$v"; then
        v=$(read_prefixed_value "$DROPIN_PATH" "Environment=${ENV_PRIO_VAR}=")
    fi
    if ! is_uint "$v"; then
        v=$(read_prefixed_value "/etc/systemd/system/$SVC_UNIT" "Environment=${ENV_PRIO_VAR}=")
    fi
    printf '%s' "$v"
}

# ------------------------------ 服务名探测 ------------------------------
is_valid_unit_base() { [[ "${1:-}" =~ ^[A-Za-z0-9_.@-]+$ ]]; }

# 从子模块 install.sh 的 `systemctl enable <unit>` 指令推断主服务名。
detect_service_name_from_repo() {
    local name=""
    if [ -f "$SUBMODULE_DIR/install.sh" ]; then
        name=$(
            grep -oE 'systemctl (enable|restart|start) (--[a-zA-Z-]+ )* [A-Za-z0-9_.@-]+\.service' \
                "$SUBMODULE_DIR/install.sh" 2>/dev/null |
                head -n1 |
                grep -oE '[A-Za-z0-9_.@-]+\.service$' |
                sed 's/\.service$//' || true
        )
    fi
    printf '%s' "$name"
}

init_service_name() {
    local name=""
    name=$(config_get SERVICE_NAME)
    if ! is_valid_unit_base "$name"; then
        name=$(detect_service_name_from_repo)
    fi
    if ! is_valid_unit_base "$name"; then
        name=$SERVICE_NAME_DEFAULT
    fi
    SVC_BASE="$name"
    SVC_UNIT="${SVC_BASE}.service"
    DROPIN_DIR="/etc/systemd/system/${SVC_UNIT}.d"
    DROPIN_PATH="$DROPIN_DIR/override.conf"
}

unit_exists() {
    local u=${1:-$SVC_UNIT}
    [ -f "/etc/systemd/system/$u" ] || systemctl cat "$u" >/dev/null 2>&1
}

# ------------------------------ 环境检查 ------------------------------
# 需要提权/致命的检查：dry-run 下只警告，不中断。
env_fail() {
    if [ "$DRY_RUN" = 1 ]; then
        warn "$@"
        return 0
    fi
    die 2 "$@"
}

check_linux() {
    if [ "$(uname -s)" != "Linux" ]; then
        die 2 "仅支持 Linux（当前: $(uname -s)）。本工具不适用于原生 Windows。"
    fi
}

check_systemd() {
    if [ -d /run/systemd/system ] || [ "$(cat /proc/1/comm 2>/dev/null || true)" = "systemd" ]; then
        return 0
    fi
    die 2 "未检测到 systemd（/run/systemd/system 不存在）。本工具依赖 systemd 管理服务，请在使用 systemd 的发行版上运行。"
}

# 检查 NVIDIA 官方驱动：nvidia-smi、/proc/driver/nvidia/version、Nouveau、可读显存。
detect_nvidia() {
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        env_fail "未找到 nvidia-smi：需要 NVIDIA 官方驱动（不要使用发行版自带的 Nouveau 驱动）。安装驱动后重试。"
        return 0
    fi
    if [ ! -f /proc/driver/nvidia/version ]; then
        env_fail "未找到 /proc/driver/nvidia/version：NVIDIA 官方驱动内核模块可能未加载。可尝试: sudo modprobe nvidia，并检查 dmesg。"
        return 0
    fi
    if [ -d /sys/module/nouveau ]; then
        env_fail "检测到 Nouveau 驱动正在被使用：nbd-vram 需要 NVIDIA 官方驱动。请先安装官方驱动并禁用 Nouveau（本脚本不会自动禁用 Nouveau 或修改 GRUB）。"
        return 0
    fi
    local total
    total=$(get_gpu_total_mib)
    if ! is_uint "$total" || [ "$total" -le 0 ]; then
        env_fail "nvidia-smi 无法读取 GPU 总显存。请检查驱动与 GPU 状态（lspci -k | grep -A3 NVIDIA；nvidia-smi）。"
    fi
    return 0
}

# 检查 nbd 内核模块与设备节点。
detect_nbd() {
    if ! command -v modprobe >/dev/null 2>&1; then
        env_fail "未找到 modprobe。Debian/Ubuntu: sudo apt install kmod；Fedora: sudo dnf install kmod；Arch: sudo pacman -S kmod"
        return 0
    fi
    if ! modprobe nbd 2>/dev/null && [ ! -d /sys/module/nbd ]; then
        env_fail "无法加载 nbd 内核模块。排查建议：
  1) 确认内核支持: grep CONFIG_BLK_DEV_NBD /boot/config-\$(uname -r)
  2) Debian/Ubuntu 云端镜像可能缺模块: sudo apt install linux-modules-extra-\$(uname -r)
  3) 手动加载并查看内核日志: sudo modprobe nbd max_part=0 ; dmesg | tail -20
  4) 发行版包提示: Debian/Ubuntu 'sudo apt install nbd'；Fedora 'sudo dnf install nbd'；Arch 'sudo pacman -S nbd'"
        return 0
    fi
    if [ ! -e /dev/nbd0 ]; then
        # sysfs 里有 nbd0 但缺设备节点（非 devtmpfs）时，尝试补建节点（major 43）。
        if [ -d /sys/class/block/nbd0 ] && [ "$(id -u)" -eq 0 ]; then
            info "/dev/nbd0 不存在但内核已注册 nbd0，尝试创建设备节点..."
            if ! run_cmd mknod -m 660 /dev/nbd0 b 43 0; then
                env_fail "创建 /dev/nbd0 失败。请手动执行: sudo mknod -m 660 /dev/nbd0 b 43 0，并检查 /dev 是否为 devtmpfs。"
                return 0
            fi
        fi
        if [ ! -e /dev/nbd0 ]; then
            env_fail "/dev/nbd0 不存在：nbd 设备节点未创建。排查建议:
  1) sudo modprobe nbd max_part=0 后再看 /dev/nbd*
  2) 检查 /dev 是否为 devtmpfs: stat -f -c %T /dev
  3) 查看内核日志: dmesg | grep -i nbd"
        fi
    fi
    return 0
}

check_git() {
    if ! command -v git >/dev/null 2>&1; then
        env_fail "未找到 git。Debian/Ubuntu: sudo apt install git；Fedora: sudo dnf install git；Arch: sudo pacman -S git"
        return 0
    fi
    if [ ! -f "$ROOT_DIR/.gitmodules" ]; then
        env_fail "未找到 $ROOT_DIR/.gitmodules：当前脚本似乎不在本项目的 Git 仓库根目录。"
    fi
    return 0
}

# 安装前的构建/运行依赖检查（只提示，不自动安装）。
check_build_deps() {
    local missing=()
    command -v gcc >/dev/null 2>&1 || missing+=("gcc")
    command -v nbd-client >/dev/null 2>&1 || missing+=("nbd-client")
    if [ "${#missing[@]}" -gt 0 ]; then
        env_fail "缺少依赖: ${missing[*]}。安装建议（本脚本不会自动安装）：
  Debian/Ubuntu: sudo apt install build-essential nbd
  Fedora:        sudo dnf install gcc nbd
  Arch:          sudo pacman -S gcc nbd
装好后重新执行本命令。"
    fi
    return 0
}

# libcuda.so.1 缺失只警告（风险提示），不直接判定失败。
check_libcuda() {
    if ldconfig -p 2>/dev/null | grep -q 'libcuda\.so\.1'; then
        return 0
    fi
    local p
    for p in /usr/lib/x86_64-linux-gnu/libcuda.so.1 \
        /usr/lib64/libcuda.so.1 \
        /usr/lib/wsl/lib/libcuda.so.1 \
        /usr/lib/nvidia/libcuda.so.1; do
        if [ -e "$p" ]; then
            return 0
        fi
    done
    warn "未在动态链接器缓存中找到 libcuda.so.1：CUDA 用户态库缺失，nbd-vram 守护进程可能无法启动。建议安装 NVIDIA 驱动用户态组件（Debian/Ubuntu: 对应驱动包/libnvidia-cuda1；Fedora: xorg-x11-drv-cuda；Arch: nvidia-utils）。"
    return 0
}

# ------------------------------ 子模块 ------------------------------
ensure_submodule() {
    if [ -d "$SUBMODULE_DIR" ] && [ -n "$(ls -A "$SUBMODULE_DIR" 2>/dev/null)" ]; then
        log "子模块目录已就绪: $SUBMODULE_DIR"
        return 0
    fi
    if [ ! -f "$ROOT_DIR/.gitmodules" ]; then
        die 4 "未找到 $ROOT_DIR/.gitmodules，无法初始化子模块 nbd-vram/。"
    fi
    info "子模块 nbd-vram 未初始化，执行: git -C \"$ROOT_DIR\" submodule update --init --recursive"
    if ! run_cmd git -C "$ROOT_DIR" submodule update --init --recursive; then
        local url
        url=$(git config -f "$ROOT_DIR/.gitmodules" --get submodule.nbd-vram.url 2>/dev/null || printf '未知')
        die 4 "子模块初始化失败。请检查网络/代理与子模块 URL（$url），然后手动重试:
  git -C \"$ROOT_DIR\" submodule update --init --recursive"
    fi
    if [ "$DRY_RUN" = 1 ]; then
        return 0
    fi
    if [ ! -d "$SUBMODULE_DIR" ] || [ -z "$(ls -A "$SUBMODULE_DIR" 2>/dev/null)" ]; then
        die 4 "子模块初始化后目录仍为空: $SUBMODULE_DIR。请检查网络/代理与子模块 URL 后重试。"
    fi
    ok "子模块已就绪: $SUBMODULE_DIR"
}

# 安装时核对子模块实际内容与本脚本假设（服务名、环境变量名）。
verify_submodule_facts() {
    local tmpl="$SUBMODULE_DIR/systemd/${SVC_BASE}.service"
    info "依据子模块内容核对（服务名 / 环境变量名）:"
    if [ -f "$SUBMODULE_DIR/install.sh" ]; then
        info "  服务名 $SVC_UNIT ← nbd-vram/install.sh 的 systemctl enable 指令"
    else
        warn "  未找到 nbd-vram/install.sh（子模块可能不完整）"
    fi
    if [ -f "$tmpl" ]; then
        if grep -q "Environment=${ENV_SIZE_VAR}=" "$tmpl"; then
            info "  环境变量 $ENV_SIZE_VAR ← nbd-vram/systemd/${SVC_BASE}.service"
        else
            warn "  模板 $tmpl 中未找到 $ENV_SIZE_VAR，drop-in 可能不会生效"
        fi
        if grep -q "Environment=${ENV_PRIO_VAR}=" "$tmpl"; then
            info "  环境变量 $ENV_PRIO_VAR ← nbd-vram/systemd/${SVC_BASE}.service"
        else
            warn "  模板 $tmpl 中未找到 $ENV_PRIO_VAR，drop-in 可能不会生效"
        fi
    else
        warn "  未找到子模块模板 $tmpl（若服务已安装到 /etc/systemd/system 可忽略）"
    fi
}

# ------------------------------ GPU 显存 ------------------------------
# 读取第一块 GPU 的总显存（MiB）。失败时输出为空，由调用方判断。
get_gpu_total_mib() {
    nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null |
        head -n1 |
        tr -d ' \r' || true
}

# 默认大小：GPU 总显存的 80%，向下取整到 512 MiB 的倍数（不超过总显存 80%）。
calc_default_size_mib() {
    local total=$1
    awk -v t="$total" 'BEGIN { m = int(t * 0.8 / 512); if (m < 1) m = 1; printf "%d", m * 512 }'
}

# --size（GB，可小数）→ MiB
gb_to_mib() {
    local gb=$1
    if ! [[ "$gb" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        return 1
    fi
    awk -v g="$gb" 'BEGIN { printf "%d", int(g * 1024 + 0.5) }'
}

# MiB → GB（用于把已保存的 MiB 换回 --size 参数）
mib_to_gb() {
    local mib=$1
    awk -v m="$mib" 'BEGIN { printf "%.10f", m / 1024 }'
}

# 当前生效的 swap 设备：优先 /run/nbd-vram-dev（本工具记录），其次 swapon 中的 nbd 设备。
detect_device() {
    local dev=""
    if [ -f /run/nbd-vram-dev ]; then
        dev=$(cat /run/nbd-vram-dev 2>/dev/null || true)
    fi
    if ! [[ "$dev" =~ ^/dev/nbd[0-9]+$ ]]; then
        dev=$(list_swap_names | grep -E '^/dev/nbd[0-9]+$' || true)
        dev=${dev%%$'\n'*}
    fi
    printf '%s' "$dev"
}

# 列出系统当前 swap 设备名（每行一个）。
list_swap_names() {
    if swapon --show=NAME --noheadings 2>/dev/null; then
        return 0
    fi
    swapon --show --noheadings 2>/dev/null | awk '{print $1}' || true
}

# 仅匹配 /dev/nbdN，避免把其他 swap 误判为本工具的设备。
verify_nbd_swap() {
    list_swap_names | grep -E '^/dev/nbd[0-9]+$' >/dev/null
}

# ------------------------------ systemd drop-in 与配置写入 ------------------------------
# 写入 /etc/nbd-vram-mgr.conf；打印“旧值 -> 新值”；内容未变化时不重复写。
write_config() {
    local size_mb=$1 prio=$2 device=$3
    local old_size old_prio old_svc old_dev changed=0

    old_size=$(config_get SIZE_MB)
    old_prio=$(config_get PRIORITY)
    old_svc=$(config_get SERVICE_NAME)
    old_dev=$(config_get DEVICE)

    if [ "$old_size" != "$size_mb" ]; then
        info "配置变更 SIZE_MB: ${old_size:-未设置} -> ${size_mb}"
        changed=1
    fi
    if [ "$old_prio" != "$prio" ]; then
        info "配置变更 PRIORITY: ${old_prio:-未设置} -> ${prio}"
        changed=1
    fi
    if [ "$old_svc" != "$SVC_BASE" ]; then
        info "配置变更 SERVICE_NAME: ${old_svc:-未设置} -> $SVC_BASE"
        changed=1
    fi
    if [ "$old_dev" != "$device" ]; then
        info "配置变更 DEVICE: ${old_dev:-未设置} -> ${device:-未检测到}"
        changed=1
    fi

    if [ "$changed" = 0 ]; then
        info "配置无变化: $CONFIG_FILE"
        return 0
    fi

    if [ "$DRY_RUN" = 1 ]; then
        printf '%s[模拟]%s 将写入 %s:\n' "$C_CYAN" "$C_RESET" "$CONFIG_FILE"
        printf 'SIZE_MB=%s\nPRIORITY=%s\nSERVICE_NAME=%s\nDEVICE=%s\n' \
            "$size_mb" "$prio" "$SVC_BASE" "${device:-}"
        return 0
    fi

    local tmp
    tmp=$(mktemp)
    register_tmp "$tmp"
    {
        printf '# nbd-vram-mgr 配置（由 mgr.sh 自动管理，请勿手改，改用 ./mgr.sh config）\n'
        printf 'SIZE_MB=%s\n' "$size_mb"
        printf 'PRIORITY=%s\n' "$prio"
        printf 'SERVICE_NAME=%s\n' "$SVC_BASE"
        printf 'DEVICE=%s\n' "${device:-}"
    } >"$tmp"
    install -m 644 "$tmp" "$CONFIG_FILE"
    ok "已写入配置: $CONFIG_FILE"
    log "写入配置 $CONFIG_FILE: SIZE_MB=$size_mb PRIORITY=$prio SERVICE_NAME=$SVC_BASE DEVICE=${device:-}"
}

# 创建/更新 systemd drop-in；写入前把旧 override 备份为 override.conf.bak.<时间戳>。
write_dropin() {
    local size_mb=$1 prio=$2

    if [ "$DRY_RUN" = 1 ]; then
        printf '%s[模拟]%s 将写入 %s:\n' "$C_CYAN" "$C_RESET" "$DROPIN_PATH"
        printf '[Service]\nEnvironment=%s=%s\nEnvironment=%s=%s\n' \
            "$ENV_SIZE_VAR" "$size_mb" "$ENV_PRIO_VAR" "$prio"
        return 0
    fi

    local tmp
    tmp=$(mktemp)
    register_tmp "$tmp"
    {
        printf '[Service]\n'
        printf 'Environment=%s=%s\n' "$ENV_SIZE_VAR" "$size_mb"
        printf 'Environment=%s=%s\n' "$ENV_PRIO_VAR" "$prio"
    } >"$tmp"

    if [ -f "$DROPIN_PATH" ] && cmp -s "$tmp" "$DROPIN_PATH"; then
        info "drop-in 无变化: $DROPIN_PATH"
        rm -f "$tmp"
        return 0
    fi

    local old_size old_prio
    old_size=$(read_prefixed_value "$DROPIN_PATH" "Environment=${ENV_SIZE_VAR}=")
    old_prio=$(read_prefixed_value "$DROPIN_PATH" "Environment=${ENV_PRIO_VAR}=")
    info "drop-in 变更 ${DROPIN_PATH}: ${ENV_SIZE_VAR} ${old_size:-无} -> ${size_mb}；${ENV_PRIO_VAR} ${old_prio:-无} -> ${prio}"

    if [ ! -d "$DROPIN_DIR" ]; then
        mkdir -p "$DROPIN_DIR"
        info "已创建 drop-in 目录: $DROPIN_DIR"
    fi
    if [ -f "$DROPIN_PATH" ]; then
        local bak
        bak="$DROPIN_PATH.bak.$(date +%s)"
        cp -p "$DROPIN_PATH" "$bak"
        info "已备份旧 override: $bak"
    fi
    install -m 644 "$tmp" "$DROPIN_PATH"
    ok "已写入 drop-in: $DROPIN_PATH"
    log "写入 drop-in $DROPIN_PATH: $ENV_SIZE_VAR=$size_mb $ENV_PRIO_VAR=$prio"
}

# ------------------------------ 验证与诊断 ------------------------------
wait_for_swap() {
    if [ "$DRY_RUN" = 1 ]; then
        return 0
    fi
    local i
    for ((i = 0; i < 15; i++)); do
        if verify_nbd_swap; then
            return 0
        fi
        sleep 1
    done
    return 1
}

show_diag() {
    warn "——以下为诊断信息，便于排查——"
    echo "--- systemctl status $SVC_UNIT ---"
    systemctl status "$SVC_UNIT" --no-pager --full 2>&1 | head -n 40 || true
    echo "--- journalctl -u $SVC_UNIT -n 50 ---"
    journalctl -u "$SVC_UNIT" -n 50 --no-pager 2>&1 | tail -n 50 || true
    echo "--- swapon --show ---"
    swapon --show 2>&1 || true
    echo "--- nvidia-smi ---"
    nvidia-smi 2>&1 | head -n 40 || true
    echo "--- 结束 ---"
}

# 安装后的完整验证：服务 active、swapon 出现 /dev/nbd*、nvidia-smi 可见 nbd-vram 进程。
verify_install() {
    if [ "$DRY_RUN" = 1 ]; then
        info "[模拟] 将验证: systemctl is-active $SVC_UNIT；swapon 中出现 /dev/nbd*；nvidia-smi 计算进程。"
        return 0
    fi
    local fail=0 nbd_list
    if systemctl is-active --quiet "$SVC_UNIT"; then
        ok "服务 $SVC_UNIT 处于 active 状态"
    else
        fail=1
        warn "服务 $SVC_UNIT 未处于 active 状态（可能被电源管理停用，见 /etc/nbd-vram.conf；或启动失败）。"
    fi

    wait_for_swap || true
    if verify_nbd_swap; then
        nbd_list=$(list_swap_names | grep -E '^/dev/nbd[0-9]+$' || true)
        ok "swapon 检测到 nbd swap: $(printf '%s' "$nbd_list" | tr '\n' ' ')"
    else
        fail=1
        warn "swapon 中未发现 /dev/nbd* swap。"
    fi

    if command -v nvidia-smi >/dev/null 2>&1; then
        local apps
        apps=$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv 2>/dev/null || true)
        if printf '%s\n' "$apps" | grep -qi 'nbd-vram'; then
            ok "nvidia-smi 显示 nbd-vram 进程占用显存"
        else
            warn "nvidia-smi 未显示 nbd-vram 相关进程（守护进程可能未建立 CUDA 上下文，可用 nvidia-smi 复查）。"
        fi
    fi

    if [ "$fail" = 1 ]; then
        show_diag
        die 5 "安装验证失败：请根据上方诊断信息排查（常见原因：GPU 显存不足、nbd-client 缺失、电源管理停用了服务、nbd 设备被占满）。"
    fi
    return 0
}

# 启动/重启后的轻量验证。
verify_running() {
    if [ "$DRY_RUN" = 1 ]; then
        info "[模拟] 将验证: 服务 active 且 swapon 中出现 /dev/nbd*。"
        return 0
    fi
    wait_for_swap || true
    local fail=0
    if systemctl is-active --quiet "$SVC_UNIT"; then
        ok "服务 $SVC_UNIT 运行中"
    else
        fail=1
        warn "服务 $SVC_UNIT 未处于 active 状态"
    fi
    if verify_nbd_swap; then
        ok "swapon 检测到 nbd swap"
    else
        fail=1
        warn "swapon 中未发现 /dev/nbd* swap"
    fi
    if [ "$fail" = 1 ]; then
        show_diag
        die 5 "服务验证失败，请根据上方诊断信息排查。"
    fi
    return 0
}

print_summary() {
    local size_mb=$1 prio=$2 device=$3
    echo "==================== 安装摘要 ===================="
    printf '  分配显存 (SIZE_MB) : %s MiB (%s GB)\n' "$size_mb" "$(awk -v m="$size_mb" 'BEGIN { printf "%.2f", m / 1024 }')"
    printf '  swap 优先级        : %s\n' "$prio"
    printf '  服务名             : %s\n' "$SVC_UNIT"
    printf '  设备               : %s\n' "${device:-未检测到}"
    printf '  配置文件           : %s\n' "$CONFIG_FILE"
    printf '  systemd drop-in    : %s\n' "$DROPIN_PATH"
    printf '  管理日志           : %s\n' "$LOG_FILE"
    echo "  验证结果           : 见上方 [成功]/[警告] 行"
    echo "  常用命令           : ./mgr.sh status | logs | config --size 6 | stop | uninstall"
    echo "=================================================="
}

# ------------------------------ install ------------------------------
# 解析大小：--size 优先；否则交互模式给出建议值确认，非交互用建议默认值并明确打印。
# 结果写入全局 RESOLVED_SIZE_MB（不用命令替换捕获，保证提示/交互输入可见）。
resolve_size_mb() {
    local total def_size saved input
    RESOLVED_SIZE_MB=""
    total=$(get_gpu_total_mib)
    if is_uint "$total" && [ "$total" -gt 0 ]; then
        def_size=$(calc_default_size_mib "$total")
        info "GPU 总显存: ${total} MiB；建议分配值（总显存 80%，向下取整到 512 MiB 倍数）: ${def_size} MiB"
    else
        def_size=7168
        warn "无法读取 GPU 总显存，暂以 7168 MiB 作为建议值。"
    fi

    if [ -n "$SIZE_MB_OPT" ]; then
        RESOLVED_SIZE_MB=$SIZE_MB_OPT
        return 0
    fi

    saved=$(config_get SIZE_MB)
    if ! is_uint "$saved"; then
        saved=""
    fi

    if [ -t 0 ] && [ "$ASSUME_YES" != 1 ] && [ "$DRY_RUN" != 1 ]; then
        while :; do
            if [ -n "$saved" ] && [ "$saved" != "$def_size" ]; then
                printf '请输入用于 swap 的显存大小（MiB）[建议 %s，已保存 %s，直接回车采用建议值]: ' "$def_size" "$saved"
            else
                printf '请输入用于 swap 的显存大小（MiB）[建议 %s，直接回车采用建议值]: ' "$def_size"
            fi
            read -r input || input=""
            if [ -z "$input" ]; then
                RESOLVED_SIZE_MB=$def_size
                return 0
            fi
            if is_uint "$input" && [ "$input" -ge "$MIN_SIZE_MB" ]; then
                RESOLVED_SIZE_MB=$input
                return 0
            fi
            warn "请输入不小于 ${MIN_SIZE_MB} 的整数 MiB，或直接回车采用建议值。"
        done
    fi

    info "非交互安装且未指定 --size，使用建议默认值: ${def_size} MiB（GPU 总显存 80%，向下取整到 512 MiB 倍数）。可用 --size 显式指定。"
    RESOLVED_SIZE_MB=$def_size
}

# 调用子模块安装方式（非交互；安装后的配置覆盖由本脚本 drop-in 完成）。
run_submodule_install() {
    if [ ! -f "$SUBMODULE_DIR/install.sh" ]; then
        die 4 "子模块缺少 install.sh: $SUBMODULE_DIR/install.sh。请先执行: git -C \"$ROOT_DIR\" submodule update --init --recursive"
    fi
    info "调用子模块安装脚本（stdin 重定向到 /dev/null，跳过其交互提示；显存大小随后由 drop-in 覆盖）..."
    if ! run_cmd bash "$SUBMODULE_DIR/install.sh" </dev/null; then
        die 5 "子模块 install.sh 执行失败。常见原因：缺少 nbd-client/gcc、软件源不可用、编译失败。请根据上方输出修复后重试。"
    fi
}

install_nbd_vram() {
    info "==== 安装 / 重新配置 NBD-VRAM ===="
    log "install 开始 (dry-run=$DRY_RUN yes=$ASSUME_YES)"

    # 环境检查（顺序与需求一致：Linux → systemd → root → NVIDIA → nbd → git → 依赖 → libcuda）
    check_linux
    check_systemd
    require_root
    detect_nvidia
    detect_nbd
    check_git
    check_build_deps
    check_libcuda

    ensure_submodule
    verify_submodule_facts

    local size_mb prio device
    resolve_size_mb
    size_mb=$RESOLVED_SIZE_MB
    prio=${PRIORITY_OPT:-$DEFAULT_PRIORITY}
    if ! is_uint "$prio" || [ "$prio" -gt 32767 ]; then
        die 1 "--priority 无效: '$prio'（应为 0-32767 的整数）"
    fi
    if [ "$size_mb" -lt "$MIN_SIZE_MB" ]; then
        die 1 "分配大小过小: ${size_mb} MiB（至少 ${MIN_SIZE_MB} MiB）"
    fi

    local total
    total=$(get_gpu_total_mib)
    if is_uint "$total" && [ "$total" -gt 0 ] && [ "$size_mb" -gt $((total * 80 / 100)) ]; then
        warn "指定大小 ${size_mb} MiB 超过 GPU 总显存的 80%（总显存 ${total} MiB）：可能挤占显示/计算所需显存，守护进程会按 512 MiB 步长回退。"
    fi
    if [ "$size_mb" -lt 1024 ]; then
        warn "分配大小 ${size_mb} MiB 小于 1024 MiB，子模块交互安装的最小建议为 1024 MiB。"
    fi

    confirm "即将安装/重新配置 NBD-VRAM（服务 $SVC_UNIT，分配 ${size_mb} MiB，优先级 ${prio}）。将调用子模块 install.sh 并写入 systemd drop-in。是否继续？"

    device=$(detect_device)

    # 1) 调用子模块安装方式  2) 写入配置  3) 创建 drop-in  4) daemon-reload
    # 5) enable + restart     6) 验证
    run_submodule_install
    write_config "$size_mb" "$prio" "$device"
    write_dropin "$size_mb" "$prio"

    if ! run_cmd systemctl daemon-reload; then
        die 5 "systemctl daemon-reload 执行失败。"
    fi
    if ! run_cmd systemctl enable "$SVC_UNIT"; then
        die 5 "启用服务 $SVC_UNIT 失败（服务文件可能未安装成功）。"
    fi
    info "重启服务以应用 drop-in 配置..."
    if ! run_cmd systemctl restart "$SVC_UNIT"; then
        show_diag
        die 5 "服务 $SVC_UNIT 启动/重启失败。"
    fi

    verify_install

    # 服务起来后刷新实际设备并回写配置。
    device=$(detect_device)
    if [ -n "$device" ]; then
        write_config "$size_mb" "$prio" "$device"
    fi

    print_summary "$size_mb" "$prio" "$device"
    log "install 完成: SIZE_MB=$size_mb PRIORITY=$prio DEVICE=${device:-}"
}

# ------------------------------ config ------------------------------
config_nbd_vram() {
    info "==== 更新 NBD-VRAM 配置 ===="
    check_linux
    check_systemd
    require_root

    if ! unit_exists && [ ! -f "$CONFIG_FILE" ] && [ ! -f "$DROPIN_PATH" ]; then
        die 1 "尚未检测到已安装的 NBD-VRAM。请先执行: ./mgr.sh install"
    fi

    local old_size old_prio size_mb prio device total
    old_size=$(effective_size_mb)
    old_prio=$(effective_priority)
    is_uint "$old_size" || old_size=""
    if ! is_uint "$old_prio" || [ "$old_prio" -gt 32767 ]; then
        old_prio=""
    fi

    size_mb=${SIZE_MB_OPT:-${old_size:-}}
    prio=${PRIORITY_OPT:-${old_prio:-$DEFAULT_PRIORITY}}

    if [ -z "$size_mb" ]; then
        # 没有任何已保存的大小时才需要 GPU 信息来给建议值。
        detect_nvidia
        total=$(get_gpu_total_mib)
        if is_uint "$total" && [ "$total" -gt 0 ]; then
            size_mb=$(calc_default_size_mib "$total")
            info "未找到已保存的 SIZE_MB，采用建议默认值: ${size_mb} MiB（GPU 总显存 80%）"
        else
            die 2 "无法确定分配大小：既没有已保存的配置，也读不到 GPU 总显存。请用 --size 指定。"
        fi
    fi
    if [ "$size_mb" -lt "$MIN_SIZE_MB" ]; then
        die 1 "分配大小过小: ${size_mb} MiB（至少 ${MIN_SIZE_MB} MiB）"
    fi
    if ! is_uint "$prio" || [ "$prio" -gt 32767 ]; then
        die 1 "--priority 无效: '$prio'（应为 0-32767 的整数）"
    fi

    info "当前值 -> 新值: SIZE_MB ${old_size:-未设置} -> ${size_mb}；PRIORITY ${old_prio:-未设置} -> ${prio}"

    if [ "$size_mb" = "${old_size:-}" ] && [ "$prio" = "${old_prio:-}" ] && [ -f "$DROPIN_PATH" ]; then
        info "配置内容与 drop-in 均已存在且一致，仍将执行 daemon-reload 与重启以确保生效。"
    fi

    confirm "将更新 $CONFIG_FILE 与 systemd drop-in，并重启服务 $SVC_UNIT。是否继续？"

    device=$(detect_device)
    write_config "$size_mb" "$prio" "$device"
    write_dropin "$size_mb" "$prio"

    if ! run_cmd systemctl daemon-reload; then
        die 5 "systemctl daemon-reload 执行失败。"
    fi
    if ! run_cmd systemctl restart "$SVC_UNIT"; then
        show_diag
        die 5 "服务 $SVC_UNIT 重启失败。"
    fi

    verify_running
    device=$(detect_device)
    if [ -n "$device" ] && [ "$device" != "$(config_get DEVICE)" ]; then
        write_config "$size_mb" "$prio" "$device"
    fi
    ok "配置已更新并生效: SIZE_MB=$size_mb PRIORITY=$prio"
    log "config 完成: SIZE_MB=$size_mb PRIORITY=$prio"
}

# ------------------------------ start / stop / restart ------------------------------
start_service() {
    info "==== 启动 $SVC_UNIT ===="
    check_linux
    check_systemd
    require_root
    if ! unit_exists; then
        die 1 "未检测到服务 $SVC_UNIT。请先执行: ./mgr.sh install"
    fi
    if systemctl is-active --quiet "$SVC_UNIT"; then
        info "服务已在运行，无需重复启动。当前 swap:"
        swapon --show 2>/dev/null || true
        return 0
    fi
    detect_nvidia
    detect_nbd
    check_libcuda
    if ! run_cmd systemctl start "$SVC_UNIT"; then
        show_diag
        die 5 "服务 $SVC_UNIT 启动失败。"
    fi
    verify_running
    log "start 完成: $SVC_UNIT"
}

stop_service() {
    info "==== 停止 $SVC_UNIT ===="
    check_linux
    check_systemd
    require_root
    if ! unit_exists; then
        die 1 "未检测到服务 $SVC_UNIT，无需停止。（如已安装子模块组件，可执行 ./mgr.sh uninstall）"
    fi
    if ! systemctl is-active --quiet "$SVC_UNIT"; then
        info "服务当前未在运行，无需停止。"
        return 0
    fi
    confirm "将停止服务 $SVC_UNIT（服务的 ExecStop 会安全执行 swapoff）。是否继续？"
    if ! run_cmd systemctl stop "$SVC_UNIT"; then
        show_diag
        die 5 "停止服务 $SVC_UNIT 失败（swapoff 可能因内存不足无法迁回页面，请释放内存后重试）。"
    fi
    info "服务已停止。提示: /dev/nbd* 的 swap 由服务 ExecStop（nbd-vram-disconnect.sh）负责 swapoff；"
    info "若 swapon --show 中仍短暂可见，稍候再查即可。本工具不会 swapoff 非本工具管理的 swap。"
    log "stop 完成: $SVC_UNIT"
}

restart_service() {
    info "==== 重启 $SVC_UNIT ===="
    check_linux
    check_systemd
    require_root
    if ! unit_exists; then
        die 1 "未检测到服务 $SVC_UNIT。请先执行: ./mgr.sh install"
    fi
    if ! systemctl is-active --quiet "$SVC_UNIT"; then
        info "服务当前未运行，改为执行启动流程。"
        start_service
        return 0
    fi
    confirm "将重启服务 $SVC_UNIT（会先 swapoff 再重建 swap，可能较慢）。是否继续？"
    if ! run_cmd systemctl restart "$SVC_UNIT"; then
        show_diag
        die 5 "服务 $SVC_UNIT 重启失败。"
    fi
    verify_running
    log "restart 完成: $SVC_UNIT"
}

# ------------------------------ status / logs（只读） ------------------------------
show_status() {
    echo "==================== NBD-VRAM 状态 ===================="
    echo "【服务状态】$SVC_UNIT"
    if unit_exists; then
        systemctl status "$SVC_UNIT" --no-pager --full 2>&1 || true
    else
        warn "服务 $SVC_UNIT 未安装（可执行 ./mgr.sh install 安装）。"
    fi

    echo
    echo "【交换空间】"
    swapon --show 2>&1 || warn "swapon --show 执行失败。"
    local nbd_list
    nbd_list=$(list_swap_names | grep -E '^/dev/nbd[0-9]+$' || true)
    if [ -n "$nbd_list" ]; then
        printf '本工具相关 nbd swap: %s\n' "$(printf '%s' "$nbd_list" | tr '\n' ' ')"
    else
        echo "未发现 /dev/nbd* swap（服务可能未运行）。"
    fi

    echo
    echo "【显存占用】nvidia-smi --query-compute-apps"
    nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv 2>&1 || warn "nvidia-smi 不可用或当前无计算进程。"

    echo
    echo "【当前配置】$CONFIG_FILE"
    if [ -r "$CONFIG_FILE" ]; then
        cat "$CONFIG_FILE" 2>/dev/null || true
    elif [ -e "$CONFIG_FILE" ]; then
        warn "配置文件存在但不可读（需要 root）: $CONFIG_FILE"
    else
        warn "未找到 $CONFIG_FILE（尚未用本脚本安装/配置）。"
    fi
    if [ -r "$DROPIN_PATH" ]; then
        echo "【systemd drop-in】$DROPIN_PATH"
        cat "$DROPIN_PATH" 2>/dev/null || true
    fi

    echo
    echo "【最近日志】journalctl -u $SVC_UNIT -n 20"
    journalctl -u "$SVC_UNIT" -n 20 --no-pager 2>&1 || warn "无法读取服务日志（可能需要 root 或 systemd-journal 组权限）。"
    echo "======================================================"
}

show_logs() {
    echo "【服务日志】journalctl -u $SVC_UNIT -n 200"
    journalctl -u "$SVC_UNIT" -n 200 --no-pager 2>&1 || warn "无法读取服务日志（可能需要 root 或 systemd-journal 组权限）。"
    echo
    echo "管理日志路径: $LOG_FILE"
    if [ -r "$LOG_FILE" ]; then
        echo "【管理日志最近 20 行】"
        tail -n 20 "$LOG_FILE" 2>/dev/null || true
    else
        warn "管理日志不可读或尚不存在（需要 root 才能写入/读取）: $LOG_FILE"
    fi
}

# ------------------------------ update ------------------------------
update_submodule() {
    info "==== 更新子模块 nbd-vram ===="
    check_git

    confirm "将同步子模块 nbd-vram 到仓库记录的提交（git submodule update --init --recursive）。是否继续？"

    if ! run_cmd git -C "$ROOT_DIR" submodule update --init --recursive; then
        die 4 "子模块同步失败。请检查网络与 .gitmodules 中的 URL（如仓库为 root 所有，可尝试: sudo $SCRIPT_PATH update）。"
    fi
    if [ "$DRY_RUN" != 1 ]; then
        if [ ! -d "$SUBMODULE_DIR" ] || [ -z "$(ls -A "$SUBMODULE_DIR" 2>/dev/null)" ]; then
            die 4 "子模块同步后目录仍为空: $SUBMODULE_DIR"
        fi
        ok "子模块已同步: $SUBMODULE_DIR"
    fi

    if [ "$OPT_REMOTE" = 1 ]; then
        if ! run_cmd git -C "$ROOT_DIR" submodule update --remote --merge nbd-vram; then
            die 4 "拉取子模块远程更新失败（git submodule update --remote --merge nbd-vram）。请检查网络与上游仓库。"
        fi
        ok "已拉取子模块远程最新提交。"
    elif ask "是否同时拉取子模块远程最新提交（git submodule update --remote --merge nbd-vram）？"; then
        if ! run_cmd git -C "$ROOT_DIR" submodule update --remote --merge nbd-vram; then
            die 4 "拉取子模块远程更新失败（git submodule update --remote --merge nbd-vram）。请检查网络与上游仓库。"
        fi
        ok "已拉取子模块远程最新提交。"
    else
        info "已跳过远程更新；如需拉取最新代码，请交互运行 update 或追加 --remote。"
    fi

    info "子模块更新完成；不会自动删除或修改您的配置。"

    # 询问是否重新执行 install 以应用新代码（保留已保存的 SIZE_MB / PRIORITY）。
    if ask "是否立即重新执行 install 以应用更新后的代码与配置？"; then
        local sz pr args=()
        sz=$(effective_size_mb)
        pr=$(effective_priority)
        is_uint "$sz" || sz=""
        if is_uint "$pr" && [ "$pr" -le 32767 ]; then :; else pr=""; fi
        args=(install --yes)
        if [ -n "$sz" ]; then
            args+=(--size "$(mib_to_gb "$sz")")
        fi
        if [ -n "$pr" ]; then
            args+=(--priority "$pr")
        fi
        if [ "$(id -u)" -eq 0 ]; then
            SIZE_MB_OPT=${sz:-}
            PRIORITY_OPT=${pr:-}
            ASSUME_YES=1
            install_nbd_vram
        else
            info "重新安装需要 root 权限，将通过 sudo 执行: sudo $SCRIPT_PATH ${args[*]}"
            if [ "$DRY_RUN" = 1 ]; then
                run_cmd sudo -- "$SCRIPT_PATH" "${args[@]}"
            else
                exec sudo -- "$SCRIPT_PATH" "${args[@]}"
            fi
        fi
    else
        info "如需应用更新，请稍后执行: ./mgr.sh install"
    fi
    log "update 完成"
}

# ------------------------------ uninstall ------------------------------
# 移除子模块安装的服务单元（子模块缺少 uninstall.sh 时的回退路径）。
fallback_remove_units() {
    local f base removed_any=0
    if [ -d "$SUBMODULE_DIR/systemd" ]; then
        for f in "$SUBMODULE_DIR"/systemd/*; do
            if [ -e "$f" ]; then
                base=${f##*/}
                if [ -f "/etc/systemd/system/$base" ]; then
                    run_cmd rm -f "/etc/systemd/system/$base"
                    info "已移除 /etc/systemd/system/$base"
                    removed_any=1
                fi
            fi
        done
    fi
    if [ "$removed_any" = 0 ] && [ -f "/etc/systemd/system/$SVC_UNIT" ]; then
        run_cmd rm -f "/etc/systemd/system/$SVC_UNIT"
        info "已移除 /etc/systemd/system/$SVC_UNIT"
        removed_any=1
    fi
    if [ "$removed_any" = 0 ]; then
        info "未发现需要移除的服务单元。"
    fi
    warn "提示: /usr/local/bin/nbd-vram* 等二进制可能仍存在，如需清理可手动删除（子模块 uninstall.sh 缺失时才会走到此分支）。"
}

uninstall_all() {
    info "==== 卸载 NBD-VRAM ===="
    log "uninstall 开始 (dry-run=$DRY_RUN yes=$ASSUME_YES)"
    check_linux
    check_systemd
    require_root

    confirm "将卸载 NBD-VRAM：停止并禁用服务、清理本工具创建的 drop-in 与配置、调用子模块 uninstall.sh。不会删除 nbd-vram/ 子模块目录，也不会关闭非本工具管理的 swap。是否继续？"

    local removed=() kept=()

    # 1) 停止并禁用本项目的服务/单元
    local units=() f u base disabled=""
    if [ -d "$SUBMODULE_DIR/systemd" ]; then
        for f in "$SUBMODULE_DIR"/systemd/*; do
            if [ -e "$f" ]; then
                units+=("${f##*/}")
            fi
        done
    fi
    units+=("$SVC_UNIT")
    for u in "${units[@]}"; do
        case " $disabled " in
            *" $u "*) continue ;;
        esac
        disabled="$disabled $u"
        if unit_exists "$u"; then
            if run_cmd systemctl disable --now "$u"; then
                removed+=("$u（已停止并禁用）")
            else
                warn "停止/禁用 $u 失败，继续其他清理步骤。"
            fi
        fi
    done

    # 2) 只对本工具记录过的 /dev/nbd* swap 执行 swapoff（绝不触碰其他 swap）
    local marker="" cfg_dev="" dev="" cand leftover
    if [ -f /run/nbd-vram-dev ]; then
        marker=$(cat /run/nbd-vram-dev 2>/dev/null || true)
    fi
    cfg_dev=$(config_get DEVICE)
    for cand in "$marker" "$cfg_dev"; do
        if [[ "$cand" =~ ^/dev/nbd[0-9]+$ ]] && list_swap_names | grep -qxF "$cand"; then
            dev=$cand
            break
        fi
    done
    if [ -n "$dev" ]; then
        info "检测到本工具管理的 swap 设备 $dev 仍在使用，执行 swapoff..."
        if run_cmd swapoff "$dev"; then
            removed+=("$dev（已 swapoff）")
        else
            warn "swapoff $dev 失败：可能内存不足无法迁回页面。请释放内存后手动执行: sudo swapoff $dev"
        fi
    else
        leftover=$(list_swap_names | grep -E '^/dev/nbd[0-9]+$' || true)
        if [ -n "$leftover" ]; then
            warn "发现未被本工具记录的 nbd swap（按安全原则不处理）: $(printf '%s' "$leftover" | tr '\n' ' ')"
        fi
    fi

    # 3) 删除本工具创建的 drop-in（含备份），目录非空则保留
    if [ -d "$DROPIN_DIR" ]; then
        if [ -f "$DROPIN_PATH" ]; then
            run_cmd rm -f "$DROPIN_PATH"
            removed+=("$DROPIN_PATH")
        fi
        if ls "$DROPIN_DIR"/override.conf.bak.* >/dev/null 2>&1; then
            run_cmd rm -f "$DROPIN_DIR"/override.conf.bak.*
            removed+=("$DROPIN_DIR/override.conf.bak.*（旧备份）")
        fi
        if rmdir "$DROPIN_DIR" 2>/dev/null; then
            removed+=("$DROPIN_DIR")
        else
            kept+=("$DROPIN_DIR（仍包含其他文件，已保留）")
        fi
    fi

    # 4) 删除本工具的配置文件
    if [ -f "$CONFIG_FILE" ]; then
        run_cmd rm -f "$CONFIG_FILE"
        removed+=("$CONFIG_FILE")
    fi

    # 5) 优先调用子模块卸载脚本（非交互 stdin 下其会保留 /etc/nbd-vram.conf）
    if [ -f "$SUBMODULE_DIR/uninstall.sh" ]; then
        info "调用子模块卸载脚本: nbd-vram/uninstall.sh（其末尾的询问在非交互输入下会保留 /etc/nbd-vram.conf）"
        if run_cmd bash "$SUBMODULE_DIR/uninstall.sh" </dev/null; then
            removed+=("子模块组件（服务单元、二进制、udev 规则，由 uninstall.sh 清理）")
        else
            warn "子模块 uninstall.sh 执行失败，回退为手动移除服务单元。"
            fallback_remove_units
        fi
    else
        info "子模块未提供 uninstall.sh，回退为手动移除服务单元。"
        fallback_remove_units
    fi

    # 6) 重载 systemd / udev
    run_cmd systemctl daemon-reload || warn "systemctl daemon-reload 失败。"
    if command -v udevadm >/dev/null 2>&1; then
        run_cmd udevadm control --reload-rules || warn "udevadm reload 失败（可忽略）。"
    fi

    # 清理结果
    echo "==================== 清理结果 ===================="
    if [ "${#removed[@]}" -gt 0 ]; then
        echo "  已移除:"
        for base in "${removed[@]}"; do
            printf '    - %s\n' "$base"
        done
    else
        echo "  已移除: （无需要移除的组件，重复执行无副作用）"
    fi
    if [ "${#kept[@]}" -gt 0 ]; then
        echo "  保留:"
        for base in "${kept[@]}"; do
            printf '    - %s\n' "$base"
        done
    fi
    echo "  保留: $SUBMODULE_DIR（子模块目录按设计不删除）"
    echo "  保留: /etc/nbd-vram.conf（子模块电源管理配置；如需删除请手动执行 rm /etc/nbd-vram.conf）"
    echo "  当前 swap（其他 swap 未受影响）:"
    swapon --show 2>/dev/null | sed 's/^/    /' || true
    echo "=================================================="
    log "uninstall 完成"
}

# ------------------------------ 菜单与帮助 ------------------------------
show_menu() {
    while :; do
        cat <<'MENU'
========== NBD-VRAM 管理菜单 ==========
 1. 安装/重新配置
 2. 启动
 3. 停止
 4. 重启
 5. 查查状态
 6. 查看日志
 7. 更新子模块
 8. 卸载
 0. 退出
==========================================
MENU
        local choice
        if ! read -r -p "请选择 [0-8]: " choice; then
            echo
            warn "输入已结束（非交互环境）。请直接使用子命令，例如: ./mgr.sh help"
            return 1
        fi
        case "$choice" in
            1) install_nbd_vram ;;
            2) start_service ;;
            3) stop_service ;;
            4) restart_service ;;
            5) show_status ;;
            6) show_logs ;;
            7) update_submodule ;;
            8) uninstall_all ;;
            0 | q | Q) info "已退出菜单。"; return 0 ;;
            *) warn "无效选项: $choice，请输入 0-8。" ;;
        esac
    done
}

usage() {
    cat <<'EOF'
NBD-VRAM 管理脚本 (mgr.sh)

用法:
  ./mgr.sh install [--size GB] [--priority N] [--yes] [--dry-run]
  ./mgr.sh config  [--size GB] [--priority N] [--yes] [--dry-run]
  ./mgr.sh start
  ./mgr.sh stop [--yes]
  ./mgr.sh restart [--yes]
  ./mgr.sh status
  ./mgr.sh logs
  ./mgr.sh update [--yes] [--remote]
  ./mgr.sh uninstall [--yes] [--dry-run]
  ./mgr.sh menu
  ./mgr.sh help
  （无参数时进入中文交互菜单）

子命令说明:
  install    安装或重新配置 NBD-VRAM。幂等：重复执行只更新配置并重启服务。
             流程：环境检查 → 初始化子模块 → 调用 nbd-vram/install.sh →
             写入 /etc/nbd-vram-mgr.conf → 创建 systemd drop-in 覆盖 →
             daemon-reload → enable/restart → 验证服务、swapon 与显存占用。
  config     更新已保存的配置与 systemd drop-in，daemon-reload 后重启并重新验证。
             修改前会打印“旧值 -> 新值”。
  start      启动服务；已在运行时友好提示。启动前做基础环境检查。
  stop       停止服务；未运行时友好提示。危险操作，默认需确认（--yes 跳过）。
             停止后 swap 由服务 ExecStop 自行 swapoff，本脚本不会 swapoff 其他 swap。
  restart    重启服务；未运行时等效于启动。
  status     只读展示：服务状态、交换空间、显存占用、当前配置、最近日志。不修改系统。
  logs       输出服务最近 200 条 journal 日志，并提示管理日志路径。
  update     同步子模块（git submodule update --init --recursive）；--remote 时同时
             拉取远程最新提交。不删除用户配置，完成后询问是否重新 install。
  uninstall  卸载：停止并禁用服务、清理本工具创建的 drop-in 与配置、优先调用子模块
             uninstall.sh。不删除 nbd-vram/ 子模块目录，不关闭非本工具管理的 swap。
             可重复执行。
  menu       显示中文交互菜单（与无参数时相同）。
  help       显示本帮助。

选项:
  --size GB       分配给 swap 的显存大小，单位 GB，允许小数（内部换算为 MiB）。
                  例如 --size 7.5 表示 7680 MiB。
  --priority N    swap 优先级，0-32767 的整数，默认 1500（越大越优先使用）。
  --yes, -y       跳过所有交互确认（用于危险操作的非交互执行）。
  --dry-run       只打印将执行的关键命令，不修改系统。
  --remote        update 时同时拉取子模块远程最新提交。
  --help, -h      显示本帮助。

默认大小规则:
  GPU 总显存的 80%，向下取整到 512 MiB 的倍数（不超过总显存 80%）。
  未指定 --size 时：交互模式给出建议值并让用户确认；非交互安装使用建议默认值
  并明确打印。

路径与文件:
  仓库根目录      由 mgr.sh 自身位置解析（支持任意当前工作目录执行）
  子模块          nbd-vram/
  配置文件        /etc/nbd-vram-mgr.conf（SIZE_MB / PRIORITY / SERVICE_NAME / DEVICE）
  systemd drop-in /etc/systemd/system/<服务名>.service.d/override.conf
  管理日志        /var/log/nbd-vram-mgr.log

退出码:
  0 成功   1 通用错误   2 环境不满足   3 权限不足   4 子模块问题   5 安装/服务操作失败

适用场景与注意:
  Linux + systemd + NVIDIA 官方驱动 + 支持 nbd 的笔记本/台式机；不适用于原生 Windows。
  显存 swap 延迟高于内存，适合冷数据；本脚本不会自动安装 NVIDIA 驱动、不会自动
  禁用 Nouveau、不会自动修改 GRUB，缺少依赖时只给出 Debian/Ubuntu、Fedora、Arch
  的安装提示。
EOF
}

# ------------------------------ 参数解析与入口 ------------------------------
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --yes | -y)
                ASSUME_YES=1
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --remote)
                OPT_REMOTE=1
                shift
                ;;
            --help | -h)
                HELP_FLAG=1
                shift
                ;;
            --size)
                if [ $# -lt 2 ]; then
                    die 1 "--size 需要数值参数（单位 GB，允许小数），例如: --size 7.5"
                fi
                SIZE_GB=$2
                shift 2
                ;;
            --size=*)
                SIZE_GB=${1#--size=}
                shift
                ;;
            --priority)
                if [ $# -lt 2 ]; then
                    die 1 "--priority 需要整数参数（0-32767），例如: --priority 1500"
                fi
                PRIORITY_OPT=$2
                shift 2
                ;;
            --priority=*)
                PRIORITY_OPT=${1#--priority=}
                shift
                ;;
            --)
                shift
                if [ $# -gt 0 ]; then
                    die 1 "不支持位置参数: $*（用 ./mgr.sh help 查看用法）"
                fi
                ;;
            -*)
                die 1 "未知选项: $1（用 ./mgr.sh help 查看用法）"
                ;;
            *)
                if [ -z "$SUBCMD" ]; then
                    SUBCMD=$1
                    shift
                else
                    die 1 "多余的参数: $1（用 ./mgr.sh help 查看用法）"
                fi
                ;;
        esac
    done

    if [ -n "$SIZE_GB" ]; then
        if ! SIZE_MB_OPT=$(gb_to_mib "$SIZE_GB"); then
            die 1 "--size 参数无效: '$SIZE_GB'（应为正数，单位 GB，允许小数，例如 --size 7.5）"
        fi
        if [ "$SIZE_MB_OPT" -lt "$MIN_SIZE_MB" ]; then
            die 1 "--size 换算后仅 ${SIZE_MB_OPT} MiB，过小（至少 ${MIN_SIZE_MB} MiB）。"
        fi
    fi
    if [ -n "$PRIORITY_OPT" ]; then
        if ! is_uint "$PRIORITY_OPT" || [ "$PRIORITY_OPT" -gt 32767 ]; then
            die 1 "--priority 参数无效: '$PRIORITY_OPT'（应为 0-32767 的整数）。"
        fi
    fi
}

main() {
    ORIG_ARGS=("$@")
    parse_args "$@"

    if [ "$HELP_FLAG" = 1 ] || [ "$SUBCMD" = "help" ]; then
        usage
        exit 0
    fi

    init_service_name

    case "$SUBCMD" in
        install) install_nbd_vram ;;
        config) config_nbd_vram ;;
        start) start_service ;;
        stop) stop_service ;;
        restart) restart_service ;;
        status) show_status ;;
        logs) show_logs ;;
        update) update_submodule ;;
        uninstall) uninstall_all ;;
        menu) show_menu ;;
        "") show_menu ;;
        *) die 1 "未知子命令: $SUBCMD（可用: install/config/start/stop/restart/status/logs/update/uninstall/menu/help）" ;;
    esac
}

main "$@" || exit $?
