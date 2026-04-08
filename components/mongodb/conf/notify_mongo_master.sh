#!/bin/bash
# Keepalived notify_master 触发时执行：强制把本节点提为 MongoDB PRIMARY
# 占位符由安装脚本 sed 替换：__MONGO_PORT__ __MONGO_USER__ __MONGO_PASS__ __MONGO_REPLSET__ __LOCAL_IP__

MONGO_PORT="__MONGO_PORT__"
MONGO_USER="__MONGO_USER__"
MONGO_PASS="__MONGO_PASS__"
MONGO_REPLSET="__MONGO_REPLSET__"
LOCAL_IP="__LOCAL_IP__"

logger "[MongoDB-HA] ${LOCAL_IP}: Promoting to PRIMARY (force reconfig)"

# 强制重配副本集，把本节点设为唯一成员并提为 PRIMARY
mongosh --port "${MONGO_PORT}" \
    -u "${MONGO_USER}" -p "${MONGO_PASS}" \
    --authenticationDatabase admin \
    --eval "
        var cfg = rs.conf();
        if (cfg === null) {
            // 副本集尚未初始化，直接 initiate
            rs.initiate({ _id: '${MONGO_REPLSET}', members: [{ _id: 0, host: '${LOCAL_IP}:${MONGO_PORT}' }] });
        } else {
            // 强制重配：只保留本节点，priority 最高
            cfg.members = [{ _id: 0, host: '${LOCAL_IP}:${MONGO_PORT}', priority: 2 }];
            cfg.version += 1;
            rs.reconfig(cfg, { force: true });
        }
    " --quiet 2>/dev/null || \
logger "[MongoDB-HA] ${LOCAL_IP}: reconfig failed, check mongod status"

echo "primary" > /var/run/mongodb-role
