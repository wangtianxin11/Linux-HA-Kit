# Keepalived 安装脚本 技术方案

## 涉及模块

- 修改：`components/keepalived/config.sh`（已有占位，补全字段定义）
- 修改：`components/keepalived/install.sh`（已有占位，实现完整安装逻辑）
- 修改：`components/keepalived/conf/keepalived.conf`（已有模板，清理健康检查块，改为占位符）

## 配置字段（config.sh）

已有字段保持不变：

| 变量名         | 说明               | 类型     | 默认值  |
|----------------|--------------------|----------|---------|
| KA_VIP         | VIP 地址（含掩码） | required | —       |
| KA_INTERFACE   | 网卡名称           | default  | eth0    |

> VIP 示例：`192.168.10.100/24`，含掩码，直接写入 `virtual_ipaddress` 块。

## conf 模板设计

基于现有 `keepalived.conf`，去掉 `vrrp_script` / `track_script` 块，保留 `notify_master` / `notify_backup`，使用以下占位符：

| 占位符              | 替换为                        |
|---------------------|-------------------------------|
| `__STATE__`         | `MASTER` 或 `BACKUP`          |
| `__INTERFACE__`     | KA_INTERFACE（如 eth0）       |
| `__PRIORITY__`      | `100`（主）或 `90`（备）      |
| `__VIP__`           | KA_VIP（如 192.168.10.100/24）|

固定值（不替换）：
- `virtual_router_id 101`
- `auth_pass 1111`
- `advert_int 1`

模板内容（最终形态）：

```
! Configuration File for keepalived

global_defs {
   notification_email {
     support@h-visions.com
   }
   notification_email_from support@h-visions.com
   smtp_server localhost
   smtp_connect_timeout 30
   script_user root
   enable_script_security
}

vrrp_instance VI_1 {
    state __STATE__
    interface __INTERFACE__
    virtual_router_id 101
    priority __PRIORITY__
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass 1111
    }
    virtual_ipaddress {
        __VIP__
    }
    notify_master "/etc/keepalived/notify_master.sh"
    notify_backup "/etc/keepalived/notify_backup.sh"
}
```

## 安装流程（install.sh）

### 整体流程

```
main()
  ├─ 仅支持 MODE=ha，否则 log_warn + return
  ├─ load_component_config "keepalived"
  ├─ 检查 KA_VIP / KA_INTERFACE 非空
  ├─ install_keepalived_on_host MASTER  MASTER  → state=MASTER priority=100
  └─ install_keepalived_on_host SLAVE   BACKUP  → state=BACKUP priority=90
```

### install_keepalived_on_host HOST USER PASS STATE PRIORITY

```
1. 检测远端 Ubuntu codename（run_remote grep VERSION_CODENAME）
2. 确认本地包路径：packages/keepalived/<codename>/keepalived-offline.tar.gz
   └─ 若不存在 → log_error + exit 1（列出期望路径）
3. 在远端建临时目录 remote_tmp=/tmp/ka_install_$$
4. scp 上传 tar.gz 到 remote_tmp/
5. scp 上传 lib/ 到 remote_tmp/lib/
6. scp 上传 components/keepalived/install.sh 到 remote_tmp/install.sh
7. scp 上传 components/keepalived/conf/keepalived.conf 到 remote_tmp/keepalived.conf.tmpl
8. run_remote 执行：
     SCRIPT_DIR=<remote_tmp> \
     KA_VIP=<vip> KA_INTERFACE=<iface> \
     KA_STATE=<state> KA_PRIORITY=<priority> \
     MODE=standalone \
     bash remote_tmp/install.sh
9. 远端清理 rm -rf remote_tmp
```

### 远端本机安装逻辑（MODE=standalone 分支）

```
_do_install_local()
  1. 解压 tar.gz 到 /tmp/ka_work_$$
  2. dpkg -i *.deb（若有依赖错误，apt-get install -f -y 修复）
  3. systemctl enable keepalived && systemctl stop keepalived || true
  4. _apply_conf()：sed 替换占位符 → /etc/keepalived/keepalived.conf
  5. systemctl start keepalived
  6. systemctl is-active keepalived → 验证
  7. 若 STATE=MASTER：ip addr show <iface> 确认 VIP 存在
  8. 清理 /tmp/ka_work_$$
```

### _apply_conf()

```bash
sed \
  -e "s/__STATE__/${KA_STATE}/g" \
  -e "s/__INTERFACE__/${KA_INTERFACE}/g" \
  -e "s/__PRIORITY__/${KA_PRIORITY}/g" \
  -e "s/__VIP__/${KA_VIP}/g" \
  "${tmpl}" > /etc/keepalived/keepalived.conf
```

## 关键流程

```
本地（install.sh main）
│
├──▶ install_keepalived_on_host MASTER(100)
│      └── _do_install_remote → 上传包+脚本+模板 → ssh执行 → 清理
│
└──▶ install_keepalived_on_host SLAVE(90)
       └── _do_install_remote → 上传包+脚本+模板 → ssh执行 → 清理
```

远端执行时 `MODE=standalone`，通过 `KA_STATE` / `KA_PRIORITY` 环境变量区分角色，避免递归 SSH（与 MySQL 同一模式）。

## 风险评估

| 风险 | 影响 | 应对策略 |
|------|------|---------|
| tar.gz 包内 deb 依赖顺序不确定 | dpkg 报缺依赖 | dpkg 失败后自动运行 `apt-get install -f -y` 兜底 |
| 日志输出污染变量（如 codename）| 路径错误 | 所有 log_* 已输出 stderr，命令替换只捕获 stdout |
| VIP 不含掩码（用户少填 /24）| keepalived 启动报错 | config.sh 提示示例含掩码，后续可加格式校验 |
| notify 脚本不存在 keepalived 报警告 | 非致命，服务可正常运行 | 安装时创建空的占位脚本（chmod +x），避免警告 |
