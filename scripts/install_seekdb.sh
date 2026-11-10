#!/usr/bin/env bash
# install_seekdb.sh — 在 Linux 上安装并启动 OceanBase seekdb 单机实例
#
# 用法:
#   sudo bash install_seekdb.sh            # 自动识别系统并安装
#   sudo bash install_seekdb.sh --dry-run  # 只打印将执行的命令
#   sudo bash install_seekdb.sh --no-start # 只安装，不启动
#
# 支持: RHEL/CentOS/Alinux/Rocky/openEuler 7/8/9、Ubuntu 22.04/24.04 (x86_64)
set -euo pipefail

BASE_URL="https://mirrors.oceanbase.com/community/stable"
SEEKDB_VERSION="1.4.0"
RPM_BUILD="100000172026082615"
DEB_BUILD="100000212026082616"
PORT="2881"

DRY_RUN=0
DO_START=1
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --no-start) DO_START=0 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "未知参数: $arg" >&2; exit 2 ;;
  esac
done

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }
run()  {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '   [dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

if [ "$DRY_RUN" -eq 0 ]; then
  [ "$(id -u)" -eq 0 ] || die "请用 root 运行（sudo bash $0）"
fi

ARCH="$(uname -m)"
[ "$ARCH" = "x86_64" ] || warn "当前架构 $ARCH 不是 x86_64，镜像目录可能没有对应的包"

[ -r /etc/os-release ] || die "读不到 /etc/os-release，无法识别系统"
# shellcheck disable=SC1091
. /etc/os-release
OS_ID="${ID:-unknown}"
OS_LIKE="${ID_LIKE:-}"
OS_VER="${VERSION_ID:-0}"
# Alinux 的 VERSION_ID 形如 "3 (OpenAnolis Edition)"，只取开头数字
MAJOR="$(printf '%s' "$OS_VER" | sed -n 's/^\([0-9][0-9]*\).*/\1/p')"
MAJOR="${MAJOR:-0}"

say "系统: $OS_ID $OS_VER ($ARCH)"

install_rpm() {
  local el="$1"
  local pkg="seekdb-${SEEKDB_VERSION}-${RPM_BUILD}.el${el}.x86_64.rpm"
  local url="${BASE_URL}/el/${el}/x86_64/${pkg}"
  local path="/tmp/${pkg}"

  say "RPM 包: $url"
  run curl -fL --retry 3 --connect-timeout 15 -o "$path" "$url"
  [ "$DRY_RUN" -eq 1 ] || [ -s "$path" ] || die "下载失败: $path 为空"

  if command -v dnf >/dev/null 2>&1; then
    run dnf -y install libaio
  elif command -v yum >/dev/null 2>&1; then
    run yum -y install libaio
  else
    warn "没有 dnf/yum，请自行确认已安装 libaio"
  fi

  if rpm -q seekdb >/dev/null 2>&1; then
    say "seekdb 主包已安装，跳过 rpm -ivh"
  else
    run rpm -ivh --nodeps "$path"
  fi
}

install_deb() {
  local codename="$1"
  local pkg="seekdb_${SEEKDB_VERSION}-${DEB_BUILD}ubuntu${OS_VER}_amd64.deb"
  local url="${BASE_URL}/ubuntu/${codename}/amd64/${pkg}"
  local path="/tmp/${pkg}"

  say "DEB 包: $url"
  run curl -fL --retry 3 --connect-timeout 15 -o "$path" "$url"
  [ "$DRY_RUN" -eq 1 ] || [ -s "$path" ] || die "下载失败: $path 为空"

  run apt-get update
  if ! run apt-get install -y libaio1t64; then
    warn "libaio1t64 装不上，回退 libaio1"
    run apt-get install -y libaio1 || warn "libaio 未安装成功，若启动报缺库请手动补装"
  fi
  run dpkg -i "$path" || warn "dpkg 返回非 0，检查上面是否只是 already installed"
}

case "$OS_ID" in
  rhel|centos|almalinux|rocky|ol|openeuler|alinux|alios|anolis|fedora|amzn)
    if [ "$MAJOR" -le 7 ] 2>/dev/null; then
      install_rpm 7
    else
      install_rpm 9
    fi
    ;;
  ubuntu)
    case "$OS_VER" in
      22.04*) install_deb jammy ;;
      24.04*) install_deb noble ;;
      *) die "未适配的 Ubuntu 版本 $OS_VER；请参考 SKILL.md 的包表手动安装" ;;
    esac
    ;;
  debian)
    die "Debian 请用官方文档确认包路径后手动安装（本脚本只覆盖 RHEL 系与 Ubuntu）"
    ;;
  *)
    if printf '%s' "$OS_LIKE" | grep -qE 'rhel|fedora|centos'; then
      if [ "$MAJOR" -le 7 ] 2>/dev/null; then install_rpm 7; else install_rpm 9; fi
    else
      die "未识别的系统: $OS_ID $OS_VER"
    fi
    ;;
esac

if [ "$DO_START" -eq 0 ]; then
  say "已跳过启动（--no-start）。手动启动: systemctl enable --now seekdb"
  exit 0
fi

say "启动 seekdb"
run systemctl daemon-reload
run systemctl enable --now seekdb

if [ "$DRY_RUN" -eq 1 ]; then
  say "dry-run 结束"
  exit 0
fi

say "等待端口 ${PORT} 就绪（最多 120 秒）"
for _ in $(seq 1 60); do
  if ss -lnt 2>/dev/null | grep -q ":${PORT} " || (echo >"/dev/tcp/127.0.0.1/${PORT}") >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

if systemctl is-active --quiet seekdb; then
  say "seekdb 已启动。下一步: sudo bash scripts/verify_seekdb.sh"
else
  warn "seekdb 未处于 active 状态，最近日志:"
  journalctl -u seekdb -n 40 --no-pager || true
  exit 1
fi
