# Repository Guidelines

## 项目结构与模块组织
本仓库是面向 Ubuntu 的 Bash 热备安装框架。`install.sh` 是交互式主入口，负责环境检查、全局配置和组件安装流程。公共能力位于 `lib/`，包括日志、远端执行、菜单交互和组件配置管理。各组件位于 `components/<name>/`，通常包含 `config.sh`、`install.sh` 以及 `conf/` 模板目录。需求、方案和任务拆分文档位于 `specs/`。运行时生成的敏感文件与离线安装包不纳入版本控制：`conf/global.conf`、`packages/`。

## 构建、测试与开发命令
- `bash install.sh`：启动主安装脚本，建议在真实终端中运行。
- `./install.sh`：等价入口；脚本会在需要时自动切换到 Bash。
- `bash -n install.sh lib/*.sh components/*/*.sh`：检查脚本语法。
- `git diff --check`：检查空白字符和补丁格式问题。

本项目没有独立的编译步骤，交付内容主要是 Shell 脚本和配置模板。

## 代码风格与命名约定
统一使用 Bash（`#!/usr/bin/env bash`），并保持 Bash 4+ 兼容。可执行安装脚本优先使用 `set -euo pipefail`。缩进使用 4 个空格，变量展开一律加双引号。函数名采用 `snake_case`，如 `install_mysql_on_host`；常量和导出环境变量使用全大写，如 `MASTER_HOST`、`MYSQL_PORT`。新增组件时保持既有目录结构：`components/<component>/config.sh` 与 `components/<component>/install.sh`。

## 测试指南
当前仓库未引入自动化测试框架。提交前至少执行语法检查，并在终端中进行针对性人工验证。涉及组件改动时，尽量覆盖 `standalone` 与 `ha` 两种路径，重点确认远端拷贝、配置文件生成和 `/tmp` 临时目录清理逻辑。若行为变更，请同步更新 `specs/<feature>/` 文档。

## 提交与 Pull Request 规范
仓库历史同时存在普通提交和 Conventional Commits，建议统一使用 `feat:`、`fix:`、`docs:` 等前缀。提交标题应简短明确，例如 `feat: 增加 MongoDB 安装脚本`。PR 需说明变更范围、影响的组件、人工验证步骤；若修改了交互菜单或终端输出，附上截图或关键输出更易评审。

## 安全与配置提示
严禁提交明文密码、`conf/global.conf` 或离线安装包。请优先复用 `lib/common.sh` 中的日志函数；这些函数输出到 stderr，可避免污染命令替换结果。新增 `components/*/conf/` 模板时，使用清晰占位符，并在脚本中明确替换规则。
