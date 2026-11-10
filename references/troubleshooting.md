# seekdb 部署排障手册

按「服务 → 端口 → SQL → 遥测文件 → 上报」的顺序排查，前一步不过就不用看后面。

## 1. 服务起不来

```bash
systemctl status seekdb --no-pager
journalctl -u seekdb -n 200 --no-pager
```

### 1.1 缺 libaio

特征：日志或 `ldd /usr/bin/seekdb` 出现 `libaio.so.1: cannot open shared object file`。

```bash
# RHEL 系
dnf -y install libaio
# Ubuntu 24.04
apt-get install -y libaio1t64
# Ubuntu 22.04
apt-get install -y libaio1
```

### 1.2 数据目录权限

数据目录（默认 `/var/lib/seekdb`）必须可写。手工 `mkdir` 过目录、或从别的机器拷贝过数据时最容易踩：

```bash
ls -ld /var/lib/seekdb
# 按安装包创建的用户修正，例如：
chown -R seekdb:seekdb /var/lib/seekdb
```

### 1.3 配置项越界（`-4016`）

`-4016` 是 seekdb 的非法参数错误，常见于内存预算、磁盘比例、路径写错。
先用最小配置启动，再逐项加回：

```bash
cp /etc/seekdb/seekdb.cnf /etc/seekdb/seekdb.cnf.bak
# 只保留端口、数据目录、内存预算，重启验证
systemctl restart seekdb
```

### 1.4 端口被占

```bash
ss -lntp | grep 2881
```

占用者不是 seekdb 时，改端口或停掉占用进程；只监听 `127.0.0.1` 时，远程连不上是预期行为，按需改 `bind_address`。

### 1.5 内存不够

4 GiB 以下的机器建议把内存预算调小；bootstrap 阶段 OOM 会表现为进程被 kill、日志无明确报错。
`dmesg -T | tail -50` 可确认是否有 OOM killer。

## 2. 端口通了，SQL 连不上

- 刚启动的 10–60 秒内是 bootstrap 阶段，重试即可。
- 用 `mysql -h127.0.0.1 -P2881 -uroot`；远程连接改成实际 IP，并确认监听地址。
- 客户端版本过旧也可能握手失败，换 `mariadb` 或 `obclient` 新版本。

## 3. 找不到 telemetry.json

已知位置（按优先级）：

1. `<数据目录>/run/telemetry.json`（默认 `/var/lib/seekdb/run/telemetry.json`）
2. `/etc/seekdb/telemetry.json`
3. 容器镜像内 `/var/lib/oceanbase/run/telemetry.json`

常见原因：

- **实例还没完成首次 bootstrap**：等 1–2 分钟再看。
- **不是用 systemd 启动**：手工在前台或自定义脚本拉起时，工作目录/运行目录可能不同，用 `find / -xdev -name 'telemetry*.json'` 定位。
- **容器 scope 环境**：部分容器平台里 `generate_id()` 取不到 machine-id / scope id，文件根本不会生成。实测在 AMD Radeon Cloud 的 k8s 工作空间里手工装 seekdb 就复现过；换普通 Linux + systemd 即可。
- **部署目录被移动**：UUID 由「机器标识 + 部署目录 + 容器 scope」派生，目录变了可能重新生成。

遥测 UUID 是**实例凭证**，不要外发；也不要把别人的 UUID 填到自己名下（校验侧会核对派生关系）。

## 4. 遥测 `sent=false`

上报端点是 `https://openwebapi.oceanbase.com/api/web/oceanbase/report`。

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://openwebapi.oceanbase.com/api/web/oceanbase/report
```

- 返回 2xx/4xx 说明网络可达，等待重试即可。
- `000` 或超时：DNS 或出网被拦，检查安全组、代理、`/etc/resolv.conf`。
- 日志里若出现 `cc=77`，通常是上报链路失败，按上面两步排查。

## 5. 安装与下载

- 官方镜像 `https://mirrors.oceanbase.com/community/stable/` 国内直连通常比 Docker Hub / ghcr 快得多。
- RHEL 系按主版本选 `el/7` 或 `el/9`；Alinux 3 实际兼容 el7 包（已实测）。
- Ubuntu 24.04 的 libaio 包名是 `libaio1t64`，不是 `libaio1`。
- Debian 未适配本脚本，按官方文档选择对应目录。

## 6. 重复部署与清理

同一台机器多次部署会留下多个 UUID，只提交**本次确认启动成功**的那一个。
彻底重来：

```bash
systemctl disable --now seekdb
rpm -e seekdb            # 或 dpkg -r seekdb
rm -rf /var/lib/seekdb
```
