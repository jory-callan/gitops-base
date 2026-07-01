# PostgreSQL Cluster (CloudNativePG)

CloudNativePG Cluster CR 定义，3 实例 HA 模式。

## 架构

```
┌─────────────────────────────────────────┐
│  postgres namespace                     │
│                                         │
│   ┌─────────┐  ┌─────────┐  ┌─────────┐│
│   │  pg-1   │  │  pg-2   │  │  pg-3   ││
│   │ (primary)│  │(replica)│  │(replica)││
│   └────┬────┘  └────┬────┘  └────┬────┘│
│        │            │            │      │
│        └────────────┴────────────┘      │
│               │ sync replication        │
│        ┌──────┴──────┐                  │
│        │  MinIO S3   │← pgBackRest      │
│        │ postgres-   │  每日全量+WAL   │
│        │ backup/     │                  │
│        └─────────────┘                  │
└─────────────────────────────────────────┘
```

## 配置要点

| 参数 | 值 | 说明 |
|------|-----|------|
| instances | 3 | 1 primary + 2 replicas |
| sync 复制 | minSync: 1 / maxSync: 2 | 至少同步 1 副本才确认写 |
| 存储 | nfs-client / 5Gi | 后续可改 storageClass |
| 资源 | 128m-512m / 128Mi-512Mi | demo 低配 |
| 备份 | 每日全量 + 持续 WAL → MinIO | 保留 7 天 |
| replica slots | enabled | 防止 replica 断开后 WAL 堆积 |

## 连接方式

Cluster 创建后会自动创建 Service：

```
# 读写（Primary）
postgres-rw.postgres.svc:5432

# 只读（Replica，可用 lb 策略）
postgres-ro.postgres.svc:5432

# 只读（Replica，轮询）
postgres-r.postgres.svc:5432
```

默认用户认证通过 operator 生成的 Secret：

```bash
# 获取 postgres 用户密码
kubectl get secret postgres-superuser -n postgres -o jsonpath='{.data.password}' | base64 -d
```

## 踩坑

1. **NFS fsync** — 当前为 demo 配置，NFS 的 `fsync` 行为不完全符合 PG 要求。如需生产，改 `storageClassName:` 即可。
2. **首启时间** — 首次部署 3 实例时会逐个创建并 streaming 同步，约 2-5 分钟完成。
3. **只读 Service** — `postgres-ro` / `postgres-r` 分别使用不同的负载均衡策略（`read` / `read-vip`），详见 CNPG 文档。

## 关联

- [cnpg-operator](../cnpg-operator/README.md) — Operator 层
