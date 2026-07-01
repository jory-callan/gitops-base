# gitops-base

k3s 集群的 ArgoCD GitOps 仓库。所有自托管应用以 Git 为单一事实来源。

## 目录结构

```
gitops-base/
├── archive/                  ← 已退役组件（旧 Loki，仅作历史参考）
├── argocd/                   ← Application CRD 定义 + 每个应用的 README
│   ├── root.yaml               App of Apps（自动同步 argocd/ 目录下的所有 application.yaml）
│   ├── project.yaml            ArgoCD Project
│   ├── metrics-server/         kubectl top 指标
│   ├── victoria-metrics/       监控（Metrics）+ Grafana 仪表盘
│   ├── victoria-logs/          日志存储
│   ├── victoria-logs-collector/日志采集 DaemonSet
│   ├── cnpg-operator/          CloudNativePG Operator（PostgreSQL HA）
│   ├── postgres/               PostgreSQL Cluster（数据面）
│   ├── redis-operator/         Redis Operator（HA 哨兵模式）
│   ├── redis/                  Redis HA（数据面）
│   ├── cert-manager/           TLS 证书管理
│   ├── gitea/                  Git 服务
│   ├── minio-operator/         MinIO 对象存储 Operator
│   ├── minio/                  MinIO 租户（数据面）
│   ├── kite/                  文件同步
│   └── kdebug/                调试 Pod
└── apps/                     ← 非 Helm 应用的原始 K8s 资源 + Helm values
    ├── cnpg-operator/values.yaml
    ├── postgres/cluster.yaml, secret.yaml, monitoring.yaml
    ├── redis-operator/values.yaml
    ├── redis/redis-replication.yaml, redis-sentinel.yaml
    ├── minio-operator/values.yaml
    ├── minio/namespace.yaml, secret.yaml, tenant.yaml, ingress*.yaml
    ├── cert-manager/cluster-issuer.yaml
    ├── kdebug/namespace.yaml, deployment.yaml, service.yaml, ingress.yaml
    └── kite/service.yaml
```

## 技术栈

| 领域 | 方案 |
|------|------|
| 集群 | k3s 3 节点 (2C8G40G) |
| GitOps | ArgoCD + App of Apps |
| 指标 | VictoriaMetrics (VMSingle) + vmagent |
| 日志 | VictoriaLogs + Collector |
| 对象存储 | MinIO Operator + Tenant（quay.io 镜像）|
| **数据库** | **CloudNativePG (PostgreSQL HA) / Redis Sentinel HA** |
| 备份 | Velero（MinIO S3 后端，每日资源备份）|
| 证书 | cert-manager + 内部 CA |
| 存储 | NFS (nfs-client) |
| 网络 | Cilium + MetalLB |
| Ingress | ingress-nginx |
| 镜像代理 | Nexus :5000-5006 |
| Helm 仓库 | Nexus :8081 |

## 快速开始

```bash
kubectl apply -f argocd/root.yaml
kubectl get application -n argocd -w
```

## 应用详解

每个应用的部署记录、配置要点、踩坑记录在其对应目录下的 `README.md`：

- [metrics-server](argocd/metrics-server/README.md)
- [victoria-metrics](argocd/victoria-metrics/README.md)（监控 + Grafana + 指标采集）
- [victoria-logs](argocd/victoria-logs/README.md)（日志存储）
- [victoria-logs-collector](argocd/victoria-logs-collector/README.md)（日志采集）
- [cert-manager](argocd/cert-manager/README.md)
- [gitea](argocd/gitea/README.md)
- [minio-operator](argocd/minio-operator/README.md)（对象存储 Operator）
- [minio](argocd/minio/README.md)（对象存储租户）
- [cnpg-operator](argocd/cnpg-operator/README.md)（PostgreSQL Operator）
- [postgres](argocd/postgres/README.md)（PostgreSQL HA Cluster）
- [redis-operator](argocd/redis-operator/README.md)（Redis Operator）
- [redis](argocd/redis/README.md)（Redis HA）
- [velero](argocd/velero/README.md)（集群备份）
- [kite](argocd/kite/README.md)
- [kdebug](argocd/kdebug/README.md)

## 日常操作

### 手动触发 ArgoCD 同步

Git push 后不想等 3 分钟轮询：

```bash

# 让 root App of Apps 立即重新扫描 argocd/ 目录
kubectl annotate application root -n argocd argocd.argoproj.io/force-sync= --overwrite

# 等几秒后看新应用出现
kubectl get application -n argocd -w | grep -E "cnpg|postgres|redis"

# 仅刷新（重新拉取 Git，对比 diff）
kubectl annotate application <app> -n argocd argocd.argoproj.io/refresh= --overwrite

# 刷新 + 强制同步（对比后立即应用）
kubectl annotate application <app> -n argocd argocd.argoproj.io/force-sync= --overwrite

# 例：kdebug 立即应用 v1.0.2
kubectl annotate application kdebug -n argocd argocd.argoproj.io/force-sync= --overwrite
```

### 查看同步状态

```bash
# 所有应用概览
kubectl get application -n argocd

# 单个应用详情（错误信息、同步日志）
kubectl get application <app> -n argocd -o wide
kubectl describe application <app> -n argocd
```

### 查看 Pod 滚动进度

```bash
kubectl get pods -n <ns> -o wide -w
kubectl describe pod -n <ns> <pod> | grep -E "Pulling|Pulled|Error|Failed|BackOff|Image:"
```

## 添加新应用

1. 创建 `argocd/<name>/application.yaml`
2. 如果需要 raw manifests，创建 `apps/<name>/` 目录放 YAML
3. 写 `README.md` 记录配置和踩坑
4. 提交推送，root App of Apps 自动同步

## 生产环境常见坑

详见各应用 README 的「踩坑」章节。主要几类：

- Helm chart 默认值不适合小集群（如 VictoriaMetrics 部分组件内存需求大）
- GitHub 在国内不可达：ArgoCD repoURL 需加 `gh-proxy.com` 前缀
- docker.io 镜像拉取失败：使用 quay.io / Nexus 镜像代理
- ArgoCD 接管已有资源时的字段不可变问题
- MinIO Operator v7.x 相对 v4.x 有 CRD 字段变更
- **PostgreSQL on NFS** — NFS 的 fsync 行为不符合 PG 的数据安全要求，当前为 demo 配置
