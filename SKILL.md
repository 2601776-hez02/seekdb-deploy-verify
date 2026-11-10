---
name: seekdb-deploy-verify
description: >-
  在 Linux 服务器上安装、启动并验证 OceanBase seekdb 单机实例，提取 run/telemetry.json
  中的部署 UUID，并排查启动失败、2881 端口不通、遥测文件缺失等问题。当用户提到 seekdb
  安装、部署、重装、启动、连接、部署 UUID 或遥测 ID 时使用。
license: Apache-2.0
metadata:
  version: 1.0.0
---

# seekdb 部署与验证

seekdb 是 OceanBase 的轻量单机数据库（MySQL 协议兼容，默认端口 2881）。
本技能覆盖「装好 → 起来 → 连上 → 拿到部署 UUID」这条最短路径，以及最常见的失败场景。

## 何时使用

- 需要在 Linux 服务器上安装或重装 seekdb。
- `systemctl status seekdb` 不是 running，或 2881 端口连不上。
- 找不到 `run/telemetry.json`，或需要提取 `content.id`（部署 UUID）。
- 想确认遥测是否已经成功上报。

不适用：多节点集群、obd 集群运维、生产级高可用 —— seekdb 是单机轻量版。

## 前置条件

| 项 | 要求 |
| --- | --- |
| 系统 | x86_64 / aarch64 Linux；RHEL 7/8/9 系（Alinux、CentOS、Rocky、openEuler）或 Ubuntu 22.04 / 24.04 |
| 权限 | root（装包与 systemd） |
| 资源 | ≥ 2 vCPU / 4 GiB 内存；数据目录 ≥ 20 GiB |
| 网络 | 能访问 `mirrors.oceanbase.com`（国内直连较快） |

## 快速路径

```bash
sudo bash scripts/install_seekdb.sh   # 识别系统 → 选包 → 安装 → 启动
sudo bash scripts/verify_seekdb.sh    # 服务 / 端口 / SQL / 遥测 UUID 一次查完
```

两条都通过即可交付。任一步失败，先看文末「故障排查」，再看 `references/troubleshooting.md`。

## 手动安装

### 第一步：选包

官方镜像根：`https://mirrors.oceanbase.com/community/stable/`

| 系统 | 目录 | 包名 |
| --- | --- | --- |
| RHEL / Alinux 7 | `el/7/x86_64/` | `seekdb-1.4.0-100000172026082615.el7.x86_64.rpm` |
| RHEL / Alinux 8、9 | `el/9/x86_64/` | `seekdb-1.4.0-100000172026082615.el9.x86_64.rpm` |
| Ubuntu 22.04 | `ubuntu/jammy/amd64/` | `seekdb_1.4.0-100000212026082616ubuntu22.04_amd64.deb` |
| Ubuntu 24.04 | `ubuntu/noble/amd64/` | `seekdb_1.4.0-100000212026082616ubuntu24.04_amd64.deb` |

> 镜像目录里同时有 `seekdb-libs`、`debuginfo` 等包，普通部署只需要 `seekdb` 主包。

### 第二步：安装

RPM：

```bash
sudo dnf -y install libaio || sudo yum -y install libaio
sudo rpm -ivh --nodeps ./seekdb-1.4.0-*.el7.x86_64.rpm
```

> 运行期只依赖 `libaio`；`--nodeps` 用来跳过镜像里没有的构建期依赖。
> 如果提示 already installed，说明主包已存在，直接进入启动步骤。

DEB：

```bash
sudo apt-get update
sudo apt-get install -y libaio1t64 || sudo apt-get install -y libaio1
sudo dpkg -i ./seekdb_1.4.0-*_amd64.deb
```

> Ubuntu 24.04 的 libaio 包名是 `libaio1t64`，22.04 是 `libaio1`。

### 第三步：启动

```bash
sudo systemctl enable --now seekdb
systemctl status seekdb --no-pager
```

首次启动会 bootstrap 数据目录（默认 `/var/lib/seekdb`），一般 10–60 秒完成。

## 验证

```bash
# 1) 服务状态
systemctl is-active seekdb

# 2) 端口监听
ss -lntp | grep 2881

# 3) SQL 连通（客户端：dnf install mariadb / apt install mariadb-client）
mysql -h127.0.0.1 -P2881 -uroot -e "select version();"
# 期望输出：5.7.25-OceanBase seekdb-v1.4.0.0

# 4) 遥测文件
sudo find /var/lib/seekdb -name 'telemetry*.json' 2>/dev/null
```

四项都满足，才算一次可交付的部署。

## 取部署 UUID

```bash
sudo python3 - <<'PY'
import json
d = json.load(open("/var/lib/seekdb/run/telemetry.json"))
print(d["content"]["id"])
PY
```

- 文件在**实例数据目录**下的 `run/telemetry.json`，不在安装包目录。
- `content.id` 是 36 位带连字符的 UUID；同一台机器重新部署可能得到新值，只提交确认启动成功的那一份。
- `content.sent` 为 `true` 表示遥测已上报；上报端点是
  `https://openwebapi.oceanbase.com/api/web/oceanbase/report`。

## 常用配置

| 项 | 位置 / 命令 |
| --- | --- |
| 配置文件 | `/etc/seekdb/seekdb.cnf` |
| 数据目录 | `/var/lib/seekdb` |
| 服务日志 | `journalctl -u seekdb -n 200 --no-pager` |
| 改端口 / 内存 | 编辑配置后 `systemctl restart seekdb` |

## 故障排查

| 现象 | 常见原因 | 处理 |
| --- | --- | --- |
| `systemctl start` 失败 | 缺 libaio、数据目录权限、配置语法 | 看 `journalctl -u seekdb -n 200`；补 libaio；确认 `/var/lib/seekdb` 属主 |
| 2881 连不上 | 服务还在 bootstrap、端口被占、只监听本地 | 等 60 秒；`ss -lntp \| grep 2881`；核对 `bind_address` |
| 启动即退出、日志见 `-4016` | 配置越界（内存 / 磁盘 / 路径） | 退回最小配置逐项打开 |
| 找不到 telemetry.json | 非 systemd 启动、容器 scope 环境、目录不对 | 用 systemd 启动；`find / -xdev -name 'telemetry*.json'`；容器内试 `/var/lib/oceanbase/run/` |
| 遥测 `sent=false` | 出网被拦或 DNS 失败 | `curl -I https://openwebapi.oceanbase.com`；放行或配置代理 |
| 第二次启动报已在运行 | 残留进程或 pid 文件 | `systemctl stop seekdb`，必要时 `pkill -f seekdb` 后重启 |
| 拉 Docker 镜像极慢 | 国内到 ghcr / quay 链路差 | 改用本文的 rpm / deb 安装，或配置镜像加速 |

更细的判定顺序见 `references/troubleshooting.md`。

## 清理

```bash
sudo systemctl disable --now seekdb
sudo rpm -e seekdb        # Ubuntu 用 sudo dpkg -r seekdb
sudo rm -rf /var/lib/seekdb
```

## 参考

- seekdb 仓库：<https://github.com/oceanbase/seekdb>
- 安装包镜像：<https://mirrors.oceanbase.com/community/stable/>
- OceanBase 文档：<https://www.oceanbase.com/docs>
<!-- OB-S:0D1kmgnl9oEkakW03By8ow -->
