# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 运行方式

```bash
# 启动主安装脚本（需要 bash 4.0+，Ubuntu 20.04 / 24.04）
bash install.sh

# 如果直接执行（脚本内部会自动切换到 bash）
./install.sh
```

脚本为全交互式 TUI，无法通过命令行参数跳过交互流程。开发/调试时只能在真实终端运行。

## 架构概述

这是一套面向 Ubuntu 的中间件热备安装框架，采用**主脚本 + 组件子脚本**的插件式架构：

```
install.sh                  # 主入口：环境检查 → 全局配置 → 组件安装循环
lib/
  common.sh                 # 公共基础库：日志、本地/远端执行、文件传输、依赖检查
  config.sh                 # 全局配置管理：读写 conf/global.conf，SSH 信息录入与校验
  menu.sh                   # 交互菜单：方向键单选（single_select）、空格多选（multi_select）
  component_config.sh       # 组件配置通用框架：字段定义式配置录入与持久化
components/<comp>/
  config.sh                 # 组件配置入口：调用 component_config 声明字段
  install.sh                # 组件安装逻辑：读取配置、本地/远端安装
  conf/                     # 组件专属配置模板（如 MySQL 的 my.cnf 模板）
  config.conf               # 组件配置持久化文件（运行时生成）
conf/
  global.conf               # 全局 SSH 配置（运行时生成，chmod 600，已 gitignore）
packages/                   # 离线 deb 包目录（已 gitignore）
  <tool>_*.deb              # 顶层：工具包（如 sshpass_1.09-1_amd64.deb）
  mysql/<codename>/         # MySQL 包按 Ubuntu 代号分目录（jammy/noble）
specs/ha-install/           # 需求规范与技术方案文档
```

## 关键设计约定

### 两种部署模式
- **standalone**（单机）：仅操作 `MASTER_HOST`，子脚本在远端以 `is_local=false` 方式执行
- **ha**（热备）：双主模式，在 `MASTER_HOST` 和 `SLAVE_HOST` 均执行安装，并配置互相复制

### 环境变量传递机制
主脚本通过 `export` 将以下变量传递给所有组件子脚本：
```
MODE, HA_TOPO, MASTER_HOST, MASTER_SSH_USER, MASTER_SSH_PASS,
SLAVE_HOST, SLAVE_SSH_USER, SLAVE_SSH_PASS, SCRIPT_DIR
```

### 组件子脚本规范
每个组件目录下需提供：
1. `config.sh`：调用 `component_config` 函数，声明配置字段（类型：`default` / `required` / `password` / `password_optional`）
2. `install.sh`：`source` `lib/common.sh` 和 `lib/component_config.sh`，调用 `load_component_config` 读取配置，根据 `$MODE` 分别处理单机/热备逻辑

### 远端安装模式（以 MySQL 为例）
热备模式下，子脚本将本身和 `lib/` 目录上传到目标机器的 `/tmp/` 临时目录，再通过 `run_remote` 在远端执行，执行完毕后清理临时文件。

### 离线依赖安装
`check_dependency <tool>` 会先检查命令是否存在，不存在则在 `packages/<tool>_*.deb` 查找离线包自动安装，找不到则打印 `apt-get install` 提示后退出。

### 组件配置持久化
组件配置保存在 `components/<comp>/config.conf`（INI 格式），下次运行时自动展示已有配置并询问是否修改。

## 新增组件

1. 在 `components/<new_comp>/` 新建 `config.sh` 和 `install.sh`
2. 在 `install.sh` 顶部的 `ALL_COMPONENTS` 数组中追加组件名（仅热备可用的放入 `HA_ONLY_COMPONENTS`）
3. `config.sh` 使用 `component_config` 函数声明字段；`install.sh` 通过 `load_component_config` 读取配置，通过 `$MODE` 判断单机/热备逻辑

## 注意事项

- `conf/global.conf` 和 `packages/` 已被 `.gitignore` 排除，含明文密码，禁止提交
- MySQL 的 `my.cnf` 模板位于 `components/mysql/conf/`，使用 `__MYSQL_PORT__`、`__SERVER_ID__`、`__AUTO_INCREMENT_OFFSET__` 占位符，由 `_apply_cnf` 函数 `sed` 替换后写入 `/etc/mysql/mysql.conf.d/mysqld.cnf`
- 所有库文件通过守卫变量（如 `_COMMON_SH_LOADED`）防止重复加载

---

## MySQL 安装脚本踩坑记录

开发过程中踩过的坑，编写其他组件安装脚本时引以为戒。

### 1. 用 `sh` 执行报 `set: Illegal option -o pipefail`

**原因**：`sh` 在 Ubuntu 上是 `dash`，不支持 `pipefail`。
**解决**：脚本开头加 sh→bash 自动切换守卫：
```bash
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi
```

### 2. `COLOR_GREEN: readonly variable`（库文件被多次 source）

**原因**：`install.sh` source 了 `common.sh`，各组件子脚本又 source 了一次，`readonly` 重复声明报错。
**解决**：所有库文件加防重复加载守卫：
```bash
[ -n "${_COMMON_SH_LOADED:-}" ] && return 0
_COMMON_SH_LOADED=1
```

### 3. 日志污染 `codename` 变量（远端安装路径出错）

**原因**：`log_info` 输出到 stdout，`codename=$(run_remote ...)` 命令替换捕获了 stdout，日志文字混入变量值，导致 `mkdir` 路径包含日志内容。
**解决**：所有日志函数（`log_info`/`log_warn`/`log_error`/`log_title`）全部改为输出到 **stderr**（`>&2`）。
⚠️ **新组件凡是在命令替换 `$(...)` 内调用的函数，必须确认其中没有 stdout 输出。**

### 4. `set -e` 下方向键菜单直接退出

**原因**：`(( current++ ))` 在值为 0 时算术运算结果为 0（假），`set -e` 把返回值非 0 的表达式当失败退出。
**解决**：改为条件式：
```bash
[ "$current" -gt 0 ] && current=$(( current - 1 )) || true
```

### 5. `${#VAR:-}: bad substitution`

**原因**：`${#...}` 获取字符串长度时，内部不能再嵌套 `:-` 默认值语法。
**解决**：先赋给临时变量再取长度：
```bash
tmp_pass="${MASTER_SSH_PASS:-}"
pass_mask=$(printf '%0.s*' $(seq 1 ${#tmp_pass}))
```

### 6. `MODE: unbound variable`（`set -u` 模式）

**原因**：`load_config` 读取文件后，如果配置文件缺某个字段，变量仍未定义，`set -u` 报错。
**解决**：`load_config` 末尾为所有变量强制赋默认值：
```bash
MODE="${MODE:-}"
MASTER_HOST="${MASTER_HOST:-}"
# ... 所有字段
```

### 7. 输入 IP/账号时退格显示 `^H`

**原因**：`read -r` 不处理退格键，退格字符会被当成普通字符输入。
**解决**：
- 普通文本输入（IP、账号）改用 `read -re`（`-e` 启用 readline，支持退格）
- 密码输入（`-s` 静默模式与 `-e` 不兼容）改为**逐字符读取**，手动处理退格：
```bash
while IFS= read -rsn1 ch; do
    if [[ "$ch" == $'\x7f' || "$ch" == $'\b' ]]; then
        input_pass="${input_pass%?}"; echo -ne '\b \b'
    elif [[ -z "$ch" ]]; then echo; break
    else input_pass+="$ch"; echo -n "*"
    fi
done
```

### 8. MySQL 复制端口问题（非 3306 端口时复制失败）

**原因**：`CHANGE MASTER TO` 语句和 `mysql` 客户端连接对端时均未指定端口，默认用 3306。
**解决**：两处都必须明确指定端口：
```sql
-- CHANGE MASTER TO 语句
MASTER_PORT=${MYSQL_PORT},
```
```bash
# 客户端连接对端时
mysql -h "${peer_host}" -P "${MYSQL_PORT}" -u replicator ...
```

### 9. 远端安装时 scp 目录结构问题

**原因**：`scp -r src dst`，当 `dst` 目录已存在时，会把 `src` 目录本身放进 `dst`（变成 `dst/src/`）而非把内容放进去。
**解决**：目标目录提前用 `mkdir -p` 建好，源路径用 `src/.`（传内容而非目录）：
```bash
scp -r "${pkg_dir}/." "${user}@${host}:${remote_tmp}/packages/mysql/${codename}/"
```

### 10. 远端递归 SSH 导致死循环

**原因**：热备模式下主脚本 SSH 到远端执行安装脚本，若远端脚本也判断 `MODE=ha` 又会 SSH 到其他机器，造成递归。
**解决**：远端执行时强制覆盖 `MODE=standalone`，用 `HA_NODE=1` 环境变量告知远端这是热备节点（使用双主配置模板）：
```bash
run_remote ... "MODE=standalone HA_NODE=1 SERVER_ID_OVERRIDE=2 bash install.sh"
```

### 11. MySQL 安装包目录按 Ubuntu 版本区分

**原因**：不同 Ubuntu 版本的 deb 包不通用（如 focal/jammy/noble 各不同）。
**解决**：包目录结构为 `packages/mysql/<codename>/`，安装时通过 `detect_ubuntu_codename` 获取本机代号，精确匹配对应目录，找不到再 fallback 到 `packages/mysql/` 根目录。

### 12. `INSTALL_COMPONENTS: unbound variable`

**原因**：`save_config` 在用户选组件之前就被调用，此时 `INSTALL_COMPONENTS` 未赋值，`set -u` 报错。
**解决**：`save_config` 中该字段改用 `${INSTALL_COMPONENTS:-}`：
```bash
INSTALL_COMPONENTS=${INSTALL_COMPONENTS:-}
```

---

## 离线包制作方法

在**有网络的同架构 Ubuntu 机器**上执行以下步骤，生成离线安装包后传输到目标服务器。

### 方法一：apt-offline（推荐，自动解析全部依赖）

```bash
# 1. 安装 apt-offline 工具
sudo apt update
sudo apt install -y apt-offline

# 2. 生成签名文件（记录所需包及依赖信息）
sudo apt-offline set <包名>.sig --install-packages <包名>

# 3. 根据签名文件下载所有包到目录
mkdir -p offline-debs
sudo apt-offline get <包名>.sig --download-dir offline-debs

# 4. 打包成 tar.gz
tar -czf <包名>-offline-complete.tar.gz -C offline-debs .

# 5. 离线机器解压后安装
tar -xzf <包名>-offline-complete.tar.gz -C /tmp/offline-debs
dpkg -i /tmp/offline-debs/*.deb
```

### 方法二：apt-get --download-only（简单快速）

```bash
# 下载指定包及所有依赖
mkdir -p offline-debs
apt-get install --download-only -o Dir::Cache::archives="$(pwd)/offline-debs" <包名>=<版本号>

# 打包成 tar.gz
tar -czf <包名>-offline-complete.tar.gz -C offline-debs .

# 离线机器解压后安装
tar -xzf <包名>-offline-complete.tar.gz -C /tmp/offline-debs
dpkg -i /tmp/offline-debs/*.deb
```

### 注意事项

- 下载机器的 Ubuntu 版本（codename）必须与目标机器一致，否则 deb 包不兼容
- 包目录按 Ubuntu 代号存放：`packages/<组件>/<codename>/`，安装脚本会自动匹配
- 常见 codename：`focal`（20.04）、`jammy`（22.04）、`noble`（24.04）
- MongoDB 各版本的包名示例：`mongodb-org=5.0.32`、`mongodb-org=6.0.x`、`mongodb-org=7.0.x`
