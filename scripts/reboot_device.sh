#!/bin/sh
# ============================================================
#  reboot_device.sh — TrollStore iOS 设备重启脚本 v1.1
#
#  适配环境: TrollStore (iOS 14-17) + 非越狱/半越狱
#  核心原理: 利用 trollstorehelper(setuid root) 代理执行 reboot
#
#  部署方式:
#   1. 上传到设备: scp reboot_device.sh mobile@<ip>:/var/mobile/
#   2. 赋权:       chmod +x /var/mobile/reboot_device.sh
#   3. 手动执行:   /bin/sh /var/mobile/reboot_device.sh
#   4. 远程调用:   curl -X POST http://<ip>:51111/api/exec -d 'cmd=/var/mobile/reboot_device.sh'
#
#  作者: TrollServer Project
#  日期: 2026-07-15
# ============================================================

set -e

# ---- 颜色输出 ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo "${GREEN}[ OK ]${NC}  $*"; }
log_warn()  { echo "${YELLOW}[WARN]${NC}  $*"; }
log_err()   { echo "${RED}[ERR ]${NC}  $*"; }

echo ""
echo "============================================================"
echo "  TrollServer 设备重启脚本 v1.1"
echo "  时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "  PID: $$  UID: $(id -u) 设备: $(uname -m)"
echo "============================================================"
echo ""

# ---- 预处理 ----
sync
log_ok "磁盘同步完成"

# ---- 策略1: 当前是 root 则直接重启 ----
if [ "$(id -u)" -eq 0 ]; then
    log_ok "当前运行于 root 权限，直接执行 reboot..."
    /sbin/reboot
    log_err "reboot 返回了（异常），尝试 reboot -q..."
    /sbin/reboot -q
    log_err "所有 root 直调方法均失败"
fi

log_warn "当前 UID=$(id -u) (mobile)，需通过 setuid 代理执行"

# ---- 策略2: 查找并使用 trollstorehelper（含全局搜索）----
HELPER=""

# 2a: 常见路径
for candidate in \
    /var/jb/usr/bin/trollstorehelper \
    /usr/bin/trollstorehelper \
    /usr/local/bin/trollstorehelper; do
    if [ -x "$candidate" ]; then
        HELPER="$candidate"
        log_ok "找到 trollstorehelper: $HELPER"
        break
    fi
done

# 2b: 全局搜索（find 命令）
if [ -z "$HELPER" ]; then
    log_info "常见路径未找到，执行全局搜索..."
    for search_dir in /usr /var/jb /private/var/jb /var/mobile; do
        if [ -d "$search_dir" ]; then
            found=$(find "$search_dir" -maxdepth 5 -name 'trollstorehelper' -type f 2>/dev/null | head -1)
            if [ -n "$found" ] && [ -x "$found" ]; then
                HELPER="$found"
                log_ok "🌍 全局搜索找到: $HELPER"
                break
            fi
        fi
    done
fi

if [ -n "$HELPER" ]; then
    # 检查 setuid 位
    if ls -la "$HELPER" | grep -q 'rws'; then
        log_ok "setuid 位已设置 ✅"
    else
        log_warn "setuid 位未设置 ⚠️ (可能无法以 root 运行)"
    fi

    # 尝试多种参数
    log_info "尝试 trollstorehelper reboot..."
    "$HELPER" reboot 2>&1 || log_warn "exit=$?"

    log_info "尝试 trollstorehelper system reboot..."
    "$HELPER" system reboot 2>&1 || log_warn "exit=$?"

    log_info "尝试 trollstorehelper /sbin/reboot..."
    "$HELPER" /sbin/reboot 2>&1 || log_warn "exit=$?"
else
    log_warn "trollstorehelper 未找到，扫描其他 setuid 二进制..."
fi

# ---- 策略3: 搜索任意 setuid root 二进制 ----
log_info "扫描 /usr/bin /usr/sbin /var/jb 中的 setuid 二进制..."
FOUND_SUID=""
for dir in /usr/bin /usr/sbin /bin /sbin /var/jb/usr/bin /var/jb/usr/sbin; do
    if [ -d "$dir" ]; then
        for f in "$dir"/*; do
            if [ -f "$f" ] && [ -u "$f" ]; then
                OWNER=$(stat -f "%Su" "$f" 2>/dev/null || stat -c "%U" "$f" 2>/dev/null || echo "?")
                if [ "$OWNER" = "root" ]; then
                    FOUND_SUID="$FOUND_SUID $f"
                fi
            fi
        done
    fi
done

if [ -n "$FOUND_SUID" ]; then
    log_ok "发现 setuid root 二进制: $FOUND_SUID"
    for suid_bin in $FOUND_SUID; do
        log_info "尝试 $suid_bin /sbin/reboot..."
        "$suid_bin" /sbin/reboot 2>&1 || log_warn "exit=$?"
    done
else
    log_warn "未找到任何 setuid 二进制"
fi

# ---- 策略3b: 全局 find 搜索所有 setuid ----
log_info "全局搜索所有 setuid root 二进制..."
ALL_SUID=$(find /usr /bin /sbin /var/jb -perm -4000 -type f -user root 2>/dev/null | head -10)
if [ -n "$ALL_SUID" ]; then
    log_ok "🌍 全局发现 setuid 二进制:"
    echo "$ALL_SUID" | while read -r f; do
        log_info "  尝试 $f /sbin/reboot..."
        "$f" /sbin/reboot 2>&1 || log_warn "exit=$?"
    done
fi

# ---- 策略4: launchctl reboot（某些 bootstrap 环境可用）----
log_info "尝试 launchctl reboot..."
launchctl reboot 2>&1 || log_warn "launchctl reboot 失败: $?"
launchctl reboot system 2>&1 || log_warn "launchctl reboot system 失败: $?"

# ---- 策略5: 直接 reboot 系统调用 ----
log_info "直接调用 /sbin/reboot..."
/sbin/reboot 2>&1 || log_err "/sbin/reboot 失败: $?"
/sbin/reboot -q 2>&1 || log_err "/sbin/reboot -q 失败: $?"

# ---- 诊断汇总 ----
echo ""
echo "============================================================"
log_err "所有重启策略均已尝试，设备未重启"
echo ""
echo "  诊断建议:"
echo "  1. 打开 TrollStore → Settings → 确认 'Enable Helper' 已开启"
echo "  2. 确认应用以 System(/Applications/) 模式安装"
echo "  3. 检查 TrollStore 版本 >= 2.0"
echo "  4. 手动检查: ls -la /var/jb/usr/bin/trollstorehelper"
echo "     应显示 rwsr-xr-x root wheel"
echo "  5. 如使用非越狱安装，可能需要 palera1n/Dopamine 等 bootstrap"
echo "  6. 提交 issue 时附带本完整日志"
echo "============================================================"
echo ""

exit 1
