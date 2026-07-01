# Redis HA

## 架构

```
┌──────────────────────────────────────────┐
│  redis namespace                         │
│                                          │
│  ┌─ RedisReplication (redis-ha) ───────┐ │
│  │  ┌──────┐  ┌──────┐  ┌──────┐      │ │
│  │  │master│  │replica│  │replica│      │ │
│  │  │pod-0 │←─│pod-1 │←─│pod-2 │      │ │
│  │  └──────┘  └──────┘  └──────┘      │ │
│  └──────────────────────────────────────┘ │
│                        ↑ monitors         │
│  ┌─ RedisSentinel ─────────────────────┐ │
│  │  ┌────────┐ ┌────────┐ ┌────────┐  │ │
│  │  │sentinel│ │sentinel│ │sentinel│  │ │
│  │  │ pod-0  │ │ pod-1  │ │ pod-2  │  │ │
│  │  └────────┘ └────────┘ └────────┘  │ │
│  └──────────────────────────────────────┘ │
└──────────────────────────────────────────┘
```

## 配置要点

| 组件 | 参数 | 值 |
|------|------|-----|
| RedisReplication | clusterSize | 3 (1 master + 2 replica) |
| RedisReplication | storage | nfs-client / 1Gi |
| RedisReplication | resource | 64m-256m / 64Mi-256Mi |
| RedisSentinel | clusterSize | 3 |
| RedisSentinel | 依赖 | 监控 `redis-ha` 复制组 |

## 连接方式

| 用途 | 地址 |
|------|------|
| 读写 Master | `redis-ha.<namespace>.svc:6379` |
| 读 Replica | 通过 sentinel 动态发现 |
| Sentinel | `redis-sentinel.<namespace>.svc:26379` |

连接时应通过 Sentinel 获取当前 master 地址，而非写死一个 Service。

## 故障切换

当 master 宕机时：
1. Sentinel 检测到 master 不可用（quorum 达成）
2. 选举一个 replica 晋升为新的 master
3. 剩余 replica 重新指向新 master
4. 原 master 恢复后成为 replica

整个过程对业务透明，只需通过 Sentinel 获取最新 master 即可。

## 踩坑

1. **quay.io 镜像** — Operator 和 Redis 镜像均来自 quay.io，确保集群可拉取
2. **反亲和** — `preferred` 而非 `required`，避免小集群调度失败
3. **exporter 密码** — redis-exporter 连接需要密码认证，operator 会自动处理

## 关联

- [redis-operator](../redis-operator/README.md) — Operator 层
