# Keepalived 安装脚本 需求规范

## 背景与目标

在热备（HA）模式下，两台服务器需要共享一个虚拟 IP（VIP），当主节点故障时 VIP 自动漂移到备节点，实现对上层服务透明的高可用切换。Keepalived 负责管理 VRRP 协议和 VIP 绑定，是整套热备方案的网络层基础。

## 用户故事

- 作为运维人员，我希望通过安装框架一键完成两台机器的 Keepalived 安装与配置，以便不需要手动登录每台机器操作。
- 作为运维人员，我希望配置好 VIP 和网卡名称后，主机宕机时 VIP 自动漂移到备机，以便上层服务不感知节点切换。

## 验收标准

- [ ] Given 热备模式且已配置 KA_VIP 和 KA_INTERFACE，When 执行安装，Then 主机和备机均成功安装 keepalived
- [ ] Given 安装完成，When 查看主机状态，Then keepalived 服务处于 active 且主机持有 VIP（ip addr 可见）
- [ ] Given 安装完成，When 模拟主机宕机（停止 keepalived），Then 备机自动获取 VIP
- [ ] Given 已有 config.conf，When 再次运行配置步骤，Then 展示已有配置并询问是否重新配置
- [ ] Given 离线包 packages/keepalived/noble/keepalived-offline.tar.gz 存在，When 执行安装，Then 无需联网完成安装

## 边界与约束

- **仅 ha 模式**：keepalived 只在热备模式下安装，standalone 模式不调用此组件
- **离线安装**：使用 `packages/keepalived/<codename>/keepalived-offline.tar.gz` 离线包，不依赖 apt 源
- **包结构**：tar.gz 解压后含多个 deb 包，通过 `dpkg -i` 按依赖顺序安装
- **远端执行**：安装在主机和备机上分别执行，通过 SSH + sshpass 完成
- **VRRP 角色**：主机为 MASTER（priority=100），备机为 BACKUP（priority=90）
- **VRRP ID**：virtual_router_id 固定为 101
- **抢占模式**：启用 preempt（主机恢复后抢回 VIP）
- **认证**：VRRP 使用明文认证（auth_type PASS），密码固定为 `1111`
- **conf 模板**：基于 `components/keepalived/conf/keepalived.conf` 现有模板，使用占位符替换；移除 `vrrp_script` / `track_script` 块（本期不做健康检查）；保留 `notify_master` / `notify_backup` 行（脚本由后续中间件创建，keepalived 安装时不创建）

## MVP 范围

**本期必做：**
- `config.sh`：声明 KA_VIP（必填）、KA_INTERFACE（默认 eth0）两个配置字段
- `install.sh`：热备模式下在主机和备机分别安装 keepalived，生成各自的 keepalived.conf，启动服务
- 离线 tar.gz 包解压安装
- 主机 MASTER / 备机 BACKUP 角色自动区分

**后续迭代：**
- 健康检查脚本（检测 nginx/mysql 进程，失败降权触发漂移）
- virtual_router_id / 认证密码 可配置化
- 多 VIP 支持
