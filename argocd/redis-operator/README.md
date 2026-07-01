# Redis Operator (OT-Container-KIT)

## 版本

| 组件 | 版本 |
|------|------|
| Chart | `redis-operator-0.25.0` |
| Operator | `0.25.0` (quay.io) |
| Redis | `v7.0.15` (实例镜像) |

## 说明

该 Operator 管理以下 CRD：

- **Redis** — 单实例
- **RedisReplication** — 主从复制（用于哨兵模式）
- **RedisSentinel** — 哨兵高可用
- **RedisCluster** — 集群模式（分片）

当前使用 **RedisReplication + RedisSentinel** 实现 HA。

## 踩坑

1. **watchNamespace** — 默认空（全集群 watch），如需要限制范围可设置 `redisOperator.watchNamespace`
2. **quay.io 镜像** — 确保镜像可拉取，当前已验证 quay.io 可达

## 关联

- [redis](../redis/README.md) — Redis HA 数据面
