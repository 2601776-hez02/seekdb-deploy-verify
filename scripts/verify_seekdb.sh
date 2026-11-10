#!/usr/bin/env bash
# verify_seekdb.sh — 一次查完 seekdb 的服务、端口、SQL 连通性与遥测 UUID
#
# 用法:
#   sudo bash verify_seekdb.sh              # 默认 127.0.0.1:2881
#   sudo bash verify_seekdb.sh --host 10.0.0.5 --port 2881
set -uo pipefail

HOST="127.0.0.1"
PORT="2881"
BASE_DIR="/var/lib/seekdb"

while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --base-dir) BASE_DIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

PASS=0
FAIL=0
WARN=0
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
note() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; WARN=$((WARN+1)); }

echo "== seekdb 部署自检 =="
echo "目标: ${HOST}:${PORT}   数据目录: ${BASE_DIR}"
echo

# 1) 服务状态
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet seekdb; then
  ok "systemctl: seekdb is active"
else
  bad "systemctl: seekdb 不是 active（journalctl -u seekdb -n 100 查看原因）"
fi

# 2) 端口监听
if ss -lnt 2>/dev/null | grep -q ":${PORT} "; then
  ok "端口 ${PORT} 正在监听"
elif (echo >"/dev/tcp/${HOST}/${PORT}") >/dev/null 2>&1; then
  ok "端口 ${PORT} 可连接（ss 不可用，已用 /dev/tcp 验证）"
else
  bad "端口 ${PORT} 不可连接"
fi

# 3) SQL 连通与版本
CLIENT=""
for c in mysql obclient; do
  if command -v "$c" >/dev/null 2>&1; then CLIENT="$c"; break; fi
done
if [ -n "$CLIENT" ]; then
  VER="$("$CLIENT" -h"$HOST" -P"$PORT" -uroot -N -e 'select version();' 2>/dev/null | head -n1)"
  if [ -n "$VER" ]; then
    ok "SQL 连通: ${VER}"
  else
    bad "SQL 连通失败（${CLIENT} 报错；确认服务已就绪、端口与账号正确）"
  fi
else
  note "未找到 mysql / obclient 客户端，跳过 SQL 检查（dnf install mariadb / apt install mariadb-client）"
fi

# 4) 遥测文件与 UUID
TELEMETRY=""
for f in "${BASE_DIR}/run/telemetry.json" "/etc/seekdb/telemetry.json" "${BASE_DIR}/etc/telemetry.json"; do
  if [ -f "$f" ]; then TELEMETRY="$f"; break; fi
done
if [ -z "$TELEMETRY" ]; then
  TELEMETRY="$(find "$BASE_DIR" /var/lib/oceanbase /etc/seekdb -maxdepth 6 -name 'telemetry*.json' 2>/dev/null | head -n1 || true)"
fi

if [ -n "$TELEMETRY" ] && [ -f "$TELEMETRY" ]; then
  if command -v python3 >/dev/null 2>&1; then
    UUID="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("content",{}).get("id",""))' "$TELEMETRY" 2>/dev/null || true)"
  elif command -v jq >/dev/null 2>&1; then
    UUID="$(jq -r '.content.id // empty' "$TELEMETRY" 2>/dev/null || true)"
  else
    UUID="$(grep -oE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' "$TELEMETRY" | head -n1 || true)"
  fi

  if [ -n "${UUID:-}" ]; then
    ok "部署 UUID: ${UUID}"
    echo "       文件: ${TELEMETRY}"
  else
    note "找到 ${TELEMETRY}，但没解析出 content.id（文件可能尚未写完）"
  fi
else
  bad "没找到 telemetry.json（确认用 systemd 启动；容器内通常在 /var/lib/oceanbase/run/）"
fi

# 5) 遥测上报端点
if command -v curl >/dev/null 2>&1; then
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 8 --max-time 15 \
    https://openwebapi.oceanbase.com/api/web/oceanbase/report 2>/dev/null || true)"
  case "$CODE" in
    2??|3??|4??) ok "遥测端点可达（HTTP ${CODE}）" ;;
    000|"") bad "遥测端点不可达（出网/DNS 被拦）" ;;
    *) note "遥测端点返回 HTTP ${CODE}" ;;
  esac
else
  note "没有 curl，跳过遥测端点检查"
fi

echo
echo "结果: pass=${PASS} fail=${FAIL} warn=${WARN}"
[ "$FAIL" -eq 0 ]
