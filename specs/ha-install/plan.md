# 热备安装脚本 技术方案

## 涉及模块

**新增文件：**
```
<脚本根目录>/
├── install.sh                      # 主脚本框架入口
├── conf/
│   └── global.conf                 # 全局配置（首次运行后自动生成）
├── lib/
│   ├── common.sh                   # 公共函数库（颜色输出、日志、sshpass执行）
│   ├── config.sh                   # 配置管理（读/写/校验 global.conf）
│   └── menu.sh                     # 交互菜单函数（单选、多选）
└── components/
    ├── mysql/install.sh            # placeholder
    ├── redis/install.sh            # placeholder
    ├── nacos/install.sh            # placeholder
    ├── mongodb/install.sh          # placeholder
    ├── nginx/install.sh            # placeholder
    └── keepalived/install.sh       # placeholder
```

---

## 主脚本流程设计

### install.sh 主流程（伪代码）

```bash
source lib/common.sh
source lib/config.sh
source lib/menu.sh

# Step 1: 全局配置检测与录入
load_or_init_config        # 读取 conf/global.conf，不存在则引导填写

# Step 2: 选择部署模式
select_deploy_mode         # 单机 / 热备-主从 / 热备-双主

# Step 3: 多选安装组件
select_components          # 展示组件列表，支持多选，热备模式才显示 Keepalived

# Step 4: 确认并执行
confirm_and_install        # 展示汇总信息，用户确认后逐个调用子脚本
```

---

## 各模块详细设计

### lib/common.sh — 公共函数库

| 函数 | 说明 |
|------|------|
| `log_info / log_warn / log_error` | 带颜色的日志输出（绿/黄/红） |
| `run_local CMD` | 本机执行命令，输出日志 |
| `run_remote HOST CMD` | 通过 sshpass 在远端执行命令 |
| `copy_to_remote HOST SRC DST` | 通过 sshpass+scp 上传文件/目录到远端 |
| `check_dependency TOOL` | 检查依赖工具是否存在（sshpass、curl 等） |

**远端执行实现：**
```bash
run_remote() {
  local host=$1; shift
  sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no \
    "${SSH_USER}@${host}" "$@"
}

copy_to_remote() {
  local host=$1 src=$2 dst=$3
  sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no \
    -r "$src" "${SSH_USER}@${host}:${dst}"
}
```

---

### lib/config.sh — 配置管理

| 函数 | 说明 |
|------|------|
| `load_config` | 读取 conf/global.conf，export 所有变量到环境 |
| `save_config` | 将当前环境变量写入 conf/global.conf，chmod 600 |
| `init_config` | 交互式引导用户填写所有配置项 |
| `show_config` | 打印当前配置，询问是否修改 |
| `validate_ssh` | 用 sshpass 测试 SSH 连通性，失败则提示重新填写 |

**global.conf 格式：**
```ini
MODE=standalone          # standalone | ha
HA_TOPO=                 # master-slave | dual-master（热备时填写）
MASTER_HOST=             # 主机 IP
SLAVE_HOST=              # 备机 IP（热备时填写）
SSH_USER=root
SSH_PASS=
INSTALL_COMPONENTS=      # 逗号分隔，如 mysql,redis,nacos
```

**配置检测逻辑：**
```
if [ -f conf/global.conf ]
  load_config → show_config → 询问是否修改
    ├─ 是 → init_config → save_config
    └─ 否 → 继续
else
  init_config → save_config
fi
```

---

### lib/menu.sh — 交互菜单

| 函数 | 说明 |
|------|------|
| `single_select TITLE OPTIONS[]` | 数字单选菜单，返回选中项 |
| `multi_select TITLE OPTIONS[]` | 空格多选菜单，回车确认，返回逗号列表 |

**多选菜单 UI 示意：**
```
请选择要安装的组件（空格选择，回车确认）：
  [*] 1. MySQL
  [ ] 2. Redis
  [*] 3. Nacos
  [ ] 4. MongoDB
  [ ] 5. Nginx
  [ ] 6. Keepalived（仅热备模式）
```

---

### 子脚本调用规范

主脚本通过**环境变量**传递上下文，子脚本直接读取：

```bash
# 主脚本调用子脚本示例
export MODE HA_TOPO MASTER_HOST SLAVE_HOST SSH_USER SSH_PASS
bash components/mysql/install.sh
```

子脚本内部约定：
- 判断 `$MODE` 决定单机或热备逻辑
- 判断 `$HA_TOPO` 决定主从或双主逻辑
- 使用 `run_remote` / `copy_to_remote` 执行远端操作

---

### components/*/install.sh — Placeholder 规范

本期所有组件子脚本均为 placeholder，输出统一提示：

```bash
#!/usr/bin/env bash
# 组件名称: MySQL
# 接收环境变量: MODE, HA_TOPO, MASTER_HOST, SLAVE_HOST, SSH_USER, SSH_PASS

source "$(dirname "$0")/../../lib/common.sh"

log_info "[MySQL] 安装脚本待实现 | MODE=${MODE} | MASTER=${MASTER_HOST}"
```

---

## 目录结构完整版

```
<脚本根目录>/
├── install.sh
├── conf/
│   └── global.conf          # chmod 600，git ignore
├── lib/
│   ├── common.sh
│   ├── config.sh
│   └── menu.sh
├── components/
│   ├── mysql/
│   │   └── install.sh
│   ├── redis/
│   │   └── install.sh
│   ├── nacos/
│   │   └── install.sh
│   ├── mongodb/
│   │   └── install.sh
│   ├── nginx/
│   │   └── install.sh
│   └── keepalived/
│       └── install.sh
└── packages/                # 离线安装包（按需放置，不纳入版本控制）
```

---

## 依赖工具

| 工具 | 用途 | 检查时机 |
|------|------|---------|
| `sshpass` | 免交互 SSH/SCP | 热备模式启动时检查，不存在则提示安装 |
| `bash ≥ 4.0` | 关联数组、多选菜单 | 脚本启动时检查 |

Ubuntu 安装 sshpass：
```bash
apt-get install -y sshpass
```

---

## 风险评估

| 风险 | 影响 | 应对策略 |
|------|------|---------|
| 明文密码写入文件 | 安全风险 | `chmod 600 conf/global.conf`，`.gitignore` 排除 |
| SSH 连通性失败 | 热备部署中断 | 配置完成后立即 `validate_ssh`，失败则重新填写 |
| sshpass 未安装 | 热备流程无法执行 | 启动时 `check_dependency sshpass`，缺失则自动提示安装命令 |
| Ubuntu 20/24 bash 版本差异 | 语法兼容问题 | 统一使用 `#!/usr/bin/env bash`，避免 bash4+ 特性，或启动时检查版本 |
