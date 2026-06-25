# minio-operator

通过 ArgoCD 部署 [MinIO Operator](https://min.io/docs/minio/kubernetes/upstream/)，负责管理 MinIO Tenant 的生命周期。

## 架构

```
MinIO Operator (v7.1.1)
  └─> 管理 Tenant CRD
        └─> minio Tenant (apps/minio/)
```

Operator v7.x 是**纯控制器**，不提供独立的 Web UI。管理用命令行：

```bash
kubectl get tenant -n minio
kubectl logs -n minio-operator deploy/minio-operator
```

## 配置要点

| 参数 | 值 | 说明 |
|------|-----|------|
| Chart | `operator` v7.1.1 | minio-operator 官方 Helm chart |
| 镜像 | `quay.io/minio/operator:v7.1.1` | quay.io 国内可拉取 |
| Namespace | `minio-operator` | 自动创建 |
| CRD | `tenants.minio.min.io` | 由 includeCRDs 自动安装 |

### Tenant 凭证

Operator v7.x 要求凭证以 `config.env` 格式保存在 Secret 中：

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: minio-env-config
  namespace: minio
type: Opaque
stringData:
  config.env: |
    export MINIO_ROOT_USER=minioadmin
    export MINIO_ROOT_PASSWORD=minioadmin
```

## 日常操作

```bash
# 查看 Operator 状态
kubectl get pods -n minio-operator

# 查看 Operator 日志
kubectl logs -n minio-operator deploy/minio-operator

# 列出所有 Tenant
kubectl get tenant -A
```

## 踩坑

### v4.x → v7.x 迁移

| 项目 | v4.3.7 | v7.1.1 |
|------|--------|--------|
| Chart 名 | `minio-operator` | `operator` |
| CRD credentials | `credsSecret` | `configuration.name` → `config.env` |
| Pool resources | `spec.resources` | `spec.pools[].resources` |
| Pool name | 可选 | **必填** |
| Console | 独立容器（需单独拉取） | MinIO Server 内嵌 9090 端口 |
| Operator Web UI | 有（console 容器） | **已移除** |
| 默认镜像 | docker.io | quay.io |
