# Keepalived 安装脚本 任务列表

## 状态说明
- [ ] 待执行  - [x] 已完成  - [~] 进行中

## 任务列表

- [x] Task 1: 更新 conf 模板 `components/keepalived/conf/keepalived.conf`
  - 删除 `vrrp_script` / `track_script` 块
  - 替换硬编码值为占位符：`__STATE__` / `__INTERFACE__` / `__PRIORITY__` / `__VIP__`
  - 保留 `notify_master` / `notify_backup` 行（路径改为 `/etc/keepalived/notify_master.sh` 和 `/etc/keepalived/notify_backup.sh`）

- [x] Task 2: 更新 `components/keepalived/config.sh`
  - 补全 KA_VIP 提示示例（含掩码格式 192.168.10.100/24）
  - 确认字段定义完整（KA_VIP required、KA_INTERFACE default eth0）

- [x] Task 3: 实现 `components/keepalived/install.sh`
  - MODE 检查：非 ha 模式打印警告并退出
  - load_component_config + 配置非空校验
  - install_keepalived_on_host 函数：检测 codename、定位离线包、上传文件到远端、远端执行、清理
  - _do_install_local 函数：解压 tar.gz、dpkg -i、创建 notify 占位脚本、_apply_conf、启动服务、验证
  - _apply_conf 函数：sed 替换四个占位符 → /etc/keepalived/keepalived.conf
  - main：分别调用 MASTER(100) 和 BACKUP(90) 安装

## 当前进度
> 尚未开始执行。
