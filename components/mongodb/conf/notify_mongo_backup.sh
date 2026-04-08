#!/bin/bash
# Keepalived notify_backup 触发时执行：把本节点降为 SECONDARY，指向对端同步
# 占位符由安装脚本 sed 替换：__MONGO_PORT__ __MONGO_USER__ __MONGO_PASS__ __MONGO_REPLSET__ __LOCAL_IP__ __PEER_IP__

MONGO_PORT="__MONGO_PORT__"
MONGO_USER="__MONGO_USER__"
MONGO_PASS="__MONGO_PASS__"
MONGO_REPLSET="__MONGO_REPLSET__"
LOCAL_IP="__LOCAL_IP__"
PEER_IP="__PEER_IP__"

logger "[MongoDB-HA] ${LOCAL_IP}: Demoting to SECONDARY, syncing from ${PEER_IP}"

# 重配副本集：把两个节点都加回来，本节点 priority 低
# 先尝试无认证（对端刚提主时可能还没认证），再尝试有认证
mongosh --port "${MONGO_PORT}" \
    -u "${MONGO_USER}" -p "${MONGO_PASS}" \
    --authenticationDatabase admin \
    --eval "
        var cfg = rs.conf();
        if (cfg === null) {
            rs.initiate({
                _id: '${MONGO_REPLSET}',
                members: [
                    { _id: 0, host: '${PEER_IP}:${MONGO_PORT}', priority: 2 },
                    { _id: 1, host: '${LOCAL_IP}:${MONGO_PORT}', priority: 1 }
                ]
            });
        } else {
            // 确保两个成员都在，本节点 priority=1，对端 priority=2
            var members = [];
            var hasPeer = false;
            var hasLocal = false;
            for (var i = 0; i < cfg.members.length; i++) {
                var h = cfg.members[i].host;
                if (h === '${PEER_IP}:${MONGO_PORT}') {
                    members.push({ _id: cfg.members[i]._id, host: h, priority: 2 });
                    hasPeer = true;
                } else if (h === '${LOCAL_IP}:${MONGO_PORT}') {
                    members.push({ _id: cfg.members[i]._id, host: h, priority: 1 });
                    hasLocal = true;
                }
            }
            if (!hasPeer) members.push({ _id: members.length, host: '${PEER_IP}:${MONGO_PORT}', priority: 2 });
            if (!hasLocal) members.push({ _id: members.length, host: '${LOCAL_IP}:${MONGO_PORT}', priority: 1 });
            cfg.members = members;
            cfg.version += 1;
            rs.reconfig(cfg, { force: true });
        }
    " --quiet 2>/dev/null || \
logger "[MongoDB-HA] ${LOCAL_IP}: reconfig failed, check mongod status"

echo "secondary" > /var/run/mongodb-role
