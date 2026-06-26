# minio

MinIO Tenant（数据面），由 [minio-operator](..//minio-operator/README.md) 管理。

## 架构

```
Tenant CR (minio.min.io/v2)
  └─> StatefulSet: minio-pool-0
       └─> Pod: minio-pool-0-0 (2 容器: minio + sidecar)
             ├── port 9000  → S3 API
             └── port 9090  → Console (Web UI)
```

## 访问

| 服务 | 地址 | 说明 |
|------|------|------|
| **Web Console** 🖥️ | `https://minio.czw-sre.internal` | 管理桶、用户、策略 |
| **S3 API** 📡 | `https://minio-api.czw-sre.internal` | 应用对接 |
| Internal S3 | `http://minio.minio.svc.cluster.local:80` | 集群内访问 |
| Internal Console | `http://minio-console.minio.svc.cluster.local:9090` | 集群内访问 |

**凭证：** `minioadmin` / `minioadmin`（见 `apps/minio/secret.yaml`）

## 程序对接

### Go

```go
client, err := minio.New("minio.minio.svc.cluster.local", &minio.Options{
    Creds:  credentials.NewStaticV2("minioadmin", "minioadmin", ""),
    Secure: false,
})
```

### Python (boto3)

```python
s3 = boto3.client(
    "s3",
    endpoint_url="http://minio.minio.svc.cluster.local:80",
    aws_access_key_id="minioadmin",
    aws_secret_access_key="minioadmin",
    region_name="us-east-1",
)
```

### Velero

```yaml
# values.yaml
configuration:
  backupStorageLocation:
    name: default
    provider: aws
    bucket: velero
    config:
      region: us-east-1
      s3Url: http://minio.minio.svc.cluster.local
      publicUrl: https://minio-api.czw-sre.internal
  volumeSnapshotLocation:
    name: default
    provider: aws
    config:
      region: us-east-1
  credential:
    name: minio-env-config
    key: config.env
```

## 默认桶

| 桶名 | 用途 |
|------|------|
| `velero` | Velero 备份 |
| `thanos` | Thanos 长期指标 |
| `loki` | 日志（参考，已被 VictoriaLogs 替代） |

## 配置要点

| 参数 | 值 | 说明 |
|------|-----|------|
| 镜像 | `quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z` | 国内可拉取 |
| 存储 | 4× 2Gi, nfs-client | RWO, 无需副本 |
| CPU request | 50m | 小集群友好 |
| Memory | 128Mi request / 512Mi limit | |
| TLS | cert-manager internal-ca | Ingress 层加密 |
| 证书自动签发 | 禁用 (`requestAutoCert: false`) | 集群内 HTTP 即可 |

## 日常操作

### Web Console

当前社区版 Console 仅提供 Object Browser（浏览/上传/下载文件）。
完整管理功能需通过 `mc` CLI 操作。

### mc 命令行管理（完整管理能力）

```bash
# 进入 MinIO Pod
kubectl exec -it -n minio minio-pool-0-0 -c minio -- sh

# 初始化配置别名
mc alias set local http://localhost:9000 minioadmin minioadmin

# ── 用户管理 ─────────────────────────────────────
mc admin user list local                 # 列出所有用户
mc admin user add local newuser newpass   # 创建用户
mc admin user disable local username      # 禁用用户
mc admin user remove local username       # 删除用户

# ── 策略管理 ─────────────────────────────────────
mc admin policy list local                # 列出所有策略
mc admin policy create local mypolicy policy.json  # 创建策略
mc admin policy set local mypolicy user=username   # 为用户绑定策略

# ── 组管理 ───────────────────────────────────────
mc admin group list local                 # 列出所有组
mc admin group add local groupname username  # 添加用户到组

# ── 服务账号 ────────────────────────────────────
mc admin user svcacct list local username  # 列出用户的服务账号
mc admin user svcacct add local username   # 创建服务账号

# ── 桶管理 ──────────────────────────────────────
mc ls local                               # 列出所有桶
mc mb local/newbucket                      # 创建桶
mc rb local/bucketname                     # 删除桶

# ── 配额与锁 ────────────────────────────────────
mc admin bucket quota info local/bucket    # 查看桶配额
mc admin bucket remote add local/bucket ...  # 配置桶复制

# ── 集群状态 ────────────────────────────────────
mc admin info local                        # 集群概览
mc admin health local                      # 健康检查
```

### 外部使用 mc 连接

```bash
# 从集群外
mc alias set remote https://minio-api.czw-sre.internal minioadmin minioadmin
mc admin info remote
```

```bash
# 查看 Tenant 状态
kubectl get tenant minio -n minio -o wide

# 查看 Tenant 详细信息
kubectl describe tenant minio -n minio

# 查看 MinIO Pod 日志
kubectl logs -n minio minio-pool-0-0 minio

# 查看 Sidecar 日志
kubectl logs -n minio minio-pool-0-0 sidecar

# 通过 mc 客户端测试
kubectl run mc-test --image=minio/mc --restart=Never -- \
  alias set local http://minio.minio.svc.cluster.local minioadmin minioadmin
kubectl logs mc-test
kubectl delete pod mc-test
```

## 踩坑

### 镜像拉取

docker.io 在国内不可达。所有 MinIO 镜像改用 **quay.io**（通过 `quay.nju.edu.cn` 镜像）：
- `quay.io/minio/operator:v7.1.1`
- `quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z`
- `quay.io/minio/operator-sidecar:v7.0.1`

### 集群 CPU 资源紧张

3 节点 × 2C，每节点仅 1 CPU 可分配给 Pod。CPU request 从 200m 降至 **50m** 才能调度。

### Operator v7.x 字段变更

详见 [minio-operator README](../minio-operator/README.md#v4x--v7x-迁移) 的迁移表。
