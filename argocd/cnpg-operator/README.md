# CloudNativePG Operator

CloudNativePG 是 PostgreSQL 的 Kubernetes Operator（CNCF Sandbox 项目）。

## 版本

| 组件 | 版本 |
|------|------|
| Chart | `cloudnative-pg-0.29.0` |
| Operator | `1.30.0` (ghcr.io) |
| PostgreSQL | `16.4` (实例镜像随 Operator 下发) |

## 目录结构

```
apps/cnpg-operator/     ← Helm values + kustomization
argocd/cnpg-operator/   ← Application CR
```

## 踩坑

1. **CRD helm.sh/resource-policy: keep** — CloudNativePG 的 CRD 标记了 `helm.sh/resource-policy: keep`，Helm uninstall 时 CRD 不会删除，需手动清理。
2. **存储** — PostgreSQL 对 NFS 延迟敏感，部署后建议确认 `fsync` 行为。当前为 demo 配置使用 NFS，生产建议换 Local PV 或 Longhorn。

## 关联

- [postgres](../postgres/README.md) — 数据面 Cluster CR
