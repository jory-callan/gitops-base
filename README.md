# gitops-base

k3s 集群的 ArgoCD GitOps 仓库。所有自托管应用以 Git 为单一事实来源。

## 目录结构

```
gitops-base/
├── archive/                  ← 已退役组件（Loki + Promtail）
├── argocd/                   ← Application CRD 定义 + 每个应用的 README
│   ├── root.yaml               App of Apps（自动同步 argocd/ 目录下的所有 application.yaml）
│   ├── project.yaml            ArgoCD Project
│   ├── metrics-server/         指标 → kubectl top
│   ├── victoria-metrics/       监控 + Grafana
│   ├── victoria-logs/          日志存储（替换 Loki）
│   ├── victoria-logs-collector/日志采集 DaemonSet（替换 Promtail）
│   ├── cert-manager/           TLS 证书管理
│   ├── cert-manager-resources/ 内部 CA
│   ├── gitea/                  Git 服务
│   ├── kite/                  文件同步
│   └── kdebug/                调试 Pod
└── apps/                     ← 非 Helm 应用的原始 K8s 资源 + README
    ├── cert-manager/cluster-issuer.yaml
    ├── kdebug/namespace.yaml, deployment.yaml, service.yaml, ingress.yaml
    └── kite/service.yaml
```

## 技术栈

| 领域 | 方案 |
|------|------|
| 集群 | k3s 3 节点 (2C8G40G) |
| GitOps | ArgoCD + App of Apps |
| 指标 | VictoriaMetrics (VMSingle) |
| 日志 | VictoriaLogs + Collector |
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
- [victoria-metrics](argocd/victoria-metrics/README.md)（含 Grafana）
- [victoria-logs](argocd/victoria-logs/README.md)
- [victoria-logs-collector](argocd/victoria-logs-collector/README.md)
- [cert-manager](argocd/cert-manager/README.md)
- [cert-manager-resources](argocd/cert-manager-resources/README.md)（内部 CA）
- [gitea](argocd/gitea/README.md)
- [kite](argocd/kite/README.md)
- [kdebug](argocd/kdebug/README.md)

## 日常操作

### 手动触发 ArgoCD 同步

Git push 后不想等 3 分钟轮询：

```bash
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

- Helm chart 默认值不适合小集群（如 Loki memcached 8GB）
- GitHub Pages / ghcr.io 在国内不可达
- ArgoCD 接管已有资源时的字段不可变问题
- 63 字符资源名限制
