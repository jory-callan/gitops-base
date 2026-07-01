# MinIO 对象存储 — 生产运维手册

MinIO Tenant（数据面）由 [minio-operator](../minio-operator/README.md) 管理。
本文档聚焦 **生产级运维操作**：声明式桶管理、IAM 权限、备份恢复、监控告警。

## 目录

1. [架构与访问](#架构与访问)
2. [声明式桶管理（推荐）](#声明式桶管理推荐)
3. [运行时桶管理（mc）](#运行时桶管理mc)
4. [IAM 权限体系](#iam-权限体系)
5. [访问密钥（Access Key）管理](#访问密钥access-key管理)
6. [生产配置要点](#生产配置要点)
7. [备份与容灾](#备份与容灾)
8. [监控与告警](#监控与告警)
9. [踩坑记录](#踩坑记录)

---

## 架构与访问

```
Tenant CR (minio.min.io/v2)
  └─> StatefulSet: minio-pool-0-{x}
       └─> Pod: minio-pool-0-0 (2 容器: minio + sidecar)
             ├── port 9000  → S3 API
             └── port 9090  → Console (Web UI)
```

| 服务 | 地址 | 说明 |
|------|------|------|
| **Web Console** | `https://minio.czw-sre.internal` | 图形化管理（浏览 + 有限管理） |
| **S3 API** | `https://minio-api.czw-sre.internal` | 应用对接（外网） |
| Internal S3 | `http://minio.minio.svc:80` | 集群内访问 |
| Internal Console | `http://minio-console.minio.svc:9090` | 集群内 Console |

**根凭证：** `minioadmin` / `minioadmin`（见 `apps/minio/secret.yaml`）

---

## 声明式桶管理（推荐）

这是 GitOps 方式，所有变更通过 `apps/minio/tenant.yaml` 提交。

### 添加一个新桶

在 `tenant.yaml` 的 `spec.buckets` 列表中添加：

```yaml
spec:
  buckets:
    - name: my-new-bucket
      region: us-east-1
    - name: another-bucket
      region: us-east-1
```

提交流程：

```bash
# 1. 编辑 tenant.yaml 添加桶
vim apps/minio/tenant.yaml

# 2. 提交推送
git add apps/minio/tenant.yaml
git commit -m "feat(minio): add my-new-bucket and another-bucket"
git push

# 3. ArgoCD 自动同步，或在集群内强制同步
kubectl annotate application minio -n argocd argocd.argoproj.io/force-sync=true --overwrite

# 4. 验证桶已创建
kubectl exec -it -n minio minio-pool-0-0 -c minio -- mc alias set local http://localhost:9000 minioadmin minioadmin
kubectl exec -it -n minio minio-pool-0-0 -c minio -- mc ls local
```

> **⚠️ 注意：** `tenant.spec.buckets` 只是**声明式创建**，不会管理桶的 ACL/策略。
> 桶级别的匿名权限（public/private）需要通过 MinIO IAM 策略另行配置。

### 删除桶

从 `spec.buckets` 列表中移除即可。ArgoCD 同步后桶会被删除（前提是桶为空）。

### 限制

- 声明式仅支持创建/删除受管桶
- 桶的**内容**（上传的文件）不受 Git 管理
- 如需复杂的桶策略（如目录级 prefix 策略），需通过 IAM 策略配置

---

## 运行时桶管理（mc）

对桶的临时操作（如清空、复制、迁移）通过 `mc` 命令执行。

### 进入 Pod 操作

```bash
kubectl exec -it -n minio minio-pool-0-0 -c minio -- sh
mc alias set local http://localhost:9000 minioadmin minioadmin
```

### 常用 mc 命令

```bash
# ── 桶基础操作 ──────────────────────────────────
mc ls local                    # 列出所有桶
mc mb local/my-new-bucket      # 运行时创建桶（不推荐，非声明式）
mc rb local/old-bucket         # 删除桶（需为空）
mc rb --force local/old-bucket # 强制删除（含非空）

# ── 桶级别操作 ─────────────────────────────────
mc stat local/my-bucket        # 查看桶信息
mc du local/my-bucket          # 查看桶使用量
mc tree local/my-bucket        # 查看桶目录树

# ── 文件操作 ──────────────────────────────────
mc cp file.txt local/my-bucket/          # 上传文件
mc cp local/my-bucket/file.txt ./        # 下载文件
mc cp --recursive local/my-bucket/ ./    # 批量下载
mc rm local/my-bucket/file.txt           # 删除文件
mc rm --recursive --older-than 30d local/my-bucket/  # 清理 30 天前的文件

# ── 桶之间同步 ─────────────────────────────────
mc mirror local/src-bucket local/dst-bucket   # 同步（增量）
mc mirror --watch local/src local/dst         # 持续同步
```

---

## IAM 权限体系

MinIO Operator v7.x 提供完整的 IAM 系统，与 AWS S3 IAM 兼容。

### 权限模型层级

```
根用户 (minioadmin) —— 超级管理员
   │
   ├── 用户 (User) —— 一个人或应用的身份
   │     └── 绑定策略 (Policy) —— 定义该用户的权限范围
   │
   ├── 组 (Group) —— 用户集合
   │     └── 绑定策略 —— 组内所有用户继承
   │
   ├── 服务账号 (Service Account) —— 与用户关联的长期密钥
   │     每个 SA 有独立的 access_key / secret_key
   │
   └── 策略 (Policy) —— JSON 格式的权限声明
         支持 IAM 兼容的 Action / Resource / Effect
```

### 策略示例

#### 1. 限制单个桶的读写权限

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::my-new-bucket",
        "arn:aws:s3:::my-new-bucket/*"
      ]
    }
  ]
}
```

#### 2. 桶完全控制（读写删）

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:*"],
      "Resource": [
        "arn:aws:s3:::my-new-bucket",
        "arn:aws:s3:::my-new-bucket/*"
      ]
    }
  ]
}
```

#### 3. 跨桶只读，特定 prefix 限制

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject"],
      "Resource": [
        "arn:aws:s3:::bucket-a/logs/*",
        "arn:aws:s3:::bucket-b/backups/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::bucket-a",
        "arn:aws:s3:::bucket-b"
      ],
      "Condition": {
        "StringLike": {
          "s3:prefix": ["logs/*", "backups/*"]
        }
      }
    }
  ]
}
```

#### 4. 桶匿名只读（公开下载）

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": "*",
      "Action": ["s3:GetObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::public-read",
        "arn:aws:s3:::public-read/*"
      ]
    }
  ]
}
```

### 创建一个新用户并绑定权限（mc）

```bash
# 进入 Pod
kubectl exec -it -n minio minio-pool-0-0 -c minio -- sh
mc alias set local http://localhost:9000 minioadmin minioadmin

# 1. 创建策略文件
cat > /tmp/app-policy.json << 'POLICY'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::my-new-bucket",
        "arn:aws:s3:::my-new-bucket/*"
      ]
    }
  ]
}
POLICY

# 2. 创建策略
mc admin policy create local my-app-policy /tmp/app-policy.json

# 3. 创建用户并设置密码
mc admin user add local my-app-user "my-secure-password"

# 4. 绑定策略到用户
mc admin policy set local my-app-policy user=my-app-user

# 5. 为该用户创建服务账号（可选，推荐作为应用的长期 AK）
#    服务账号有独立的 access_key / secret_key
#    比直接用用户密码更安全（可独立轮换）
mc admin user svcacct add local my-app-user

# 输出示例：
# Access Key: XXXXXXXX (access key)
# Secret Key: YYYYYYYY (secret key)
```

### 服务账号管理

服务账号是 MinIO **推荐**的 AK 管理方式：
- 一个用户可以拥有多个服务账号
- 每个服务账号可独立轮换（不影响其他应用）
- 服务账号可设置过期时间
- 服务账号可以绑定自己的策略（可缩小但不能扩大父用户的权限）

```bash
# 创建服务账号（指定策略缩小范围）
mc admin user svcacct add --policy /tmp/sa-policy.json local my-app-user

# 列出用户的服务账号
mc admin user svcacct list local my-app-user

# 查看服务账号信息
mc admin user svcacct info local <access-key>

# 更新服务账号（如更换密钥）
mc admin user svcacct edit --secret-key new-key local <access-key>

# 删除服务账号
mc admin user svcacct remove local <access-key>
```

---

## 访问密钥（Access Key）管理

### 应用对接的最佳实践

| 场景 | 推荐方式 | 说明 |
|------|----------|------|
| 集群内应用 | **Kubernetes Secret** + 声明式 | 见下文 |
| 集群外应用 | **服务账号** + 环境变量 | 可独立轮换 |
| 临时调试 | `minioadmin` | 仅限调试用 |
| CI/CD 流水线 | 专用用户 + 服务账号 | 需要时可吊销 |

### 集群内应用使用 Secret 挂载 AK

```yaml
# 1. 创建 Secret
apiVersion: v1
kind: Secret
metadata:
  name: minio-credentials
  namespace: my-app
type: Opaque
stringData:
  # 使用服务账号的 AK/SK，而非 root 密码
  access-key: "XXXXXXXX"
  secret-key: "YYYYYYYY"
---
# 2. 在 Deployment 中引用
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      containers:
        - name: my-app
          env:
            - name: AWS_ACCESS_KEY_ID
              valueFrom:
                secretKeyRef:
                  name: minio-credentials
                  key: access-key
            - name: AWS_SECRET_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: minio-credentials
                  key: secret-key
```

> **⚠️ 不要共享 root 凭证。** 每个应用用独立的用户 + 服务账号，
> 如果某个应用被攻破，吊销其服务账号即可，不影响其他应用和 root 用户。

### AK 轮换方案

```bash
# 1. 创建新密钥
mc admin user svcacct add --secret-key new-key local my-app-user

# 2. 更新应用的环境变量/Secret

# 3. 确认应用使用新密钥正常工作

# 4. 轮换旧密钥（或者直接删除旧 SA）
mc admin user svcacct remove local <old-access-key>
```

---

## 生产配置要点

### 当前配置评估

| 配置项 | 当前值 | 生产建议 | 说明 |
|--------|--------|----------|------|
| **实例数** | 1 (pool-0, servers: 1) | **≥4 节点多池** | 单点无高可用 |
| **存储** | NFS 4×2Gi | **Local PV / Longhorn** | NFS 不适合高性能场景 |
| **证书** | Ingress TLS (internal-ca) | ✅ 合理 | 集群内用 HTTP，外部 TLS |
| **资源** | 50m/128Mi-512Mi | ✅ 合理（demo） | 生产建议 500m/2Gi+ |
| **EC** | EC:0 | **EC:1 或 EC:2** | 纠删码保护数据，EC:0 无冗余 |

### 纠删码（Erasure Code）

EC 是 MinIO 的数据冗余机制，与 Kubernetes 的 ReplicaSet 不同。

```
EC:0   = 无冗余（当前配置，数据块写入一份，无保护）
EC:1   = 容忍 1 块盘失效（4 盘集群实际可用 2Gi × 2 = 4Gi）
EC:2   = 容忍 2 块盘失效（4 盘集群实际可用 2Gi × 1 = 2Gi）
```

修改方式：

```yaml
# tenant.yaml
spec:
  env:
    - name: MINIO_STORAGE_CLASS_STANDARD
      value: "EC:1"     # 从 EC:0 改为 EC:1
    - name: MINIO_STORAGE_CLASS_RRS
      value: "EC:1"
```

> 注意：修改 EC 只对新写入的数据生效，已有数据不会重新编码。

### 未来迁移到多池 HA

```
pools:
  - name: pool-0          # 现有 pool
    servers: 1
    volumesPerServer: 4
    ...
  - name: pool-1          # 新增 pool（跨节点）
    servers: 3
    volumesPerServer: 4
    ...
```

多池的好处：
- 数据自动在 pool 之间均衡分布
- 单个 pool 故障不影响整体可用性
- 可以滚动扩缩容

---

## 备份与容灾

MinIO 本身就充当备份存储（Velero 的后端），但 **MinIO 本身也需要备份**。

### 桶之间备份

```bash
# 每日定时同步到另一个桶 or 另一个 MinIO 实例
kubectl create cronjob -n minio minio-backup \
  --image=minio/mc \
  --schedule="0 2 * * *" \
  -- /bin/sh -c "mc alias set src http://localhost:9000 \$SRC_KEY \$SRC_SECRET && \
                 mc alias set dst http://remote-minio:9000 \$DST_KEY \$DST_SECRET && \
                 mc mirror --overwrite src/backup-bucket dst/backup-bucket"
```

### 跨站点复制（Bucket Replication）

MinIO 支持 S3 兼容的跨区域复制：

```bash
# 在源桶上配置复制到目标桶
mc admin bucket remote add src/src-bucket \
  https://dst-minio.example.com dst-bucket \
  --service replication --region us-east-1

mc replicate add src/src-bucket \
  --remote-bucket dst/dst-bucket \
  --id replicate-src-to-dst \
  --priority 1
```

### 使用 Velero 备份 MinIO 配置

```bash
# 备份 MinIO 相关资源（Tenant CR、Secret）
velero backup create minio-config --include-resources tenant,secret \
  --include-namespaces minio
```

---

## 监控与告警

### 已有监控

MinIO 自动暴露 Prometheus 指标，当前通过 ServiceMonitor 采集：

```yaml
# apps/minio/service-monitor.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: minio
  namespace: minio
spec:
  endpoints:
    - port: http
      interval: 30s
      path: /minio/v2/metrics/cluster
```

### 关键指标与告警规则

以下指标可在 VictoriaMetrics 中配置告警：

| 指标 | 告警条件 | 含义 |
|------|----------|------|
| `minio_cluster_disk_offline` | `> 0` | 磁盘离线，需立即处理 |
| `minio_cluster_disk_total` / `minio_cluster_disk_free` | 使用率 > 80% | 磁盘空间不足 |
| `minio_cluster_nodes_online` | `< 预期节点数` | 节点离线 |
| `minio_s3_requests_errors_total` | 速率 > 阈值 | 请求错误率异常 |
| `minio_bucket_usage_total_bytes` | `> 阈值` | 单桶大小超标 |

示例告警规则（可添加到 `apps/victoria-metrics/rules/`）：

```yaml
groups:
  - name: minio
    rules:
      - alert: MinioDiskOffline
        expr: minio_cluster_disk_offline > 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "MinIO 磁盘离线"
      - alert: MinioDiskUsage
        expr: (minio_cluster_disk_total - minio_cluster_disk_free) / minio_cluster_disk_total > 0.8
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "MinIO 磁盘使用率超过 80%"
      - alert: MinioNodeOffline
        expr: minio_cluster_nodes_online < 1
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "MinIO 节点离线"
```

---

## 踩坑记录

### 1. NFS 性能瓶颈

当前 MinIO 运行在 NFS 上。NFS 的单连接性能瓶颈和延迟波动会直接影响 MinIO 的 S3 上传/下载速度。

```
方案对比：
├── NFS（当前）    ⭐⭐     可工作，性能一般
├── Local PV      ⭐⭐⭐⭐   高性能，但需要节点本地盘
├── Longhorn      ⭐⭐⭐⭐   高可用块存储，建议生产用
└── 直接挂载宿主机  ⭐⭐⭐⭐⭐  最快，但运维成本高
```

### 2. 单点问题

当前 `servers: 1` 的配置意味着：
- MinIO Pod 宕机后服务不可用
- 无多盘纠删码保护
- **Pod 重启后数据还在 NFS 上，所以不会丢数据**

### 3. 声明式桶的删除行为

ArgoCD 会确保集群状态与 Git 一致：
- 如果从 `spec.buckets` 中**移除**一个桶定义，Operator 会**删除**该桶
- 删除前请确保桶已清空，否则删除失败

### 4. `mc` 命令断开连接

进入 Pod 执行 mc 时，每次都需要重新 alias：

```bash
mc alias set local http://localhost:9000 minioadmin minioadmin
```

也可以写到 shell profile：

```bash
echo 'mc alias set local http://localhost:9000 $MINIO_ROOT_USER $MINIO_ROOT_PASSWORD' >> ~/.bashrc
```

### 5. EC:0 的数据风险

当前 `EC:0` 表示没有纠删码保护。如果 Pod 重启或磁盘发生静默错误，数据可能损坏。
至少应该升到 `EC:1`。
