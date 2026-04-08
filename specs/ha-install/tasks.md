# 热备安装脚本 任务列表

## 状态说明
- [ ] 待执行
- [x] 已完成
- [~] 进行中

---

## 任务列表

### 基础结构

- [x] Task 1: 创建完整目录结构及 .gitignore
  - 创建 `conf/` `lib/` `components/mysql|redis|nacos|mongodb|nginx|keepalived/` `packages/` 目录
  - 创建 `conf/.gitignore`，排除 `global.conf` 和 `packages/`

### 公共库

- [x] Task 2: 编写 `lib/common.sh` — 公共函数库
  - `log_info / log_warn / log_error`（带颜色输出）
  - `run_local CMD`
  - `run_remote HOST CMD`
  - `copy_to_remote HOST SRC DST`
  - `check_dependency TOOL`

- [x] Task 3: 编写 `lib/menu.sh` — 交互菜单库
  - `single_select TITLE OPTIONS[]` 数字单选
  - `multi_select TITLE OPTIONS[]` 空格多选 + 回车确认

- [x] Task 4: 编写 `lib/config.sh` — 配置管理库
  - `load_config`：读取 `conf/global.conf` 并 export 变量
  - `save_config`：将变量写入文件并 `chmod 600`
  - `init_config`：交互式引导填写所有配置项
  - `show_config`：打印当前配置，询问是否修改
  - `validate_ssh HOST`：测试 SSH 连通性

### 主脚本

- [x] Task 5: 编写 `install.sh` — 主脚本框架
  - 检查 bash 版本 ≥ 4
  - Step1: 调用 `load_or_init_config`
  - Step2: 调用 `select_deploy_mode`（单机 / 热备-主从 / 热备-双主）
  - Step3: 调用 `select_components`（多选，热备时显示 Keepalived）
  - Step4: 展示安装汇总，用户确认后逐个调用子脚本

### 组件 Placeholder

- [x] Task 6: 编写 `components/mysql/install.sh` placeholder
- [x] Task 7: 编写 `components/redis/install.sh` placeholder
- [x] Task 8: 编写 `components/nacos/install.sh` placeholder
- [x] Task 9: 编写 `components/mongodb/install.sh` placeholder
- [x] Task 10: 编写 `components/nginx/install.sh` placeholder
- [x] Task 11: 编写 `components/keepalived/install.sh` placeholder

---

## 当前进度

> 全部 11 个任务已完成。
