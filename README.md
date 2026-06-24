# gitops-base — ArgoCD GitOps 应用管理

通过 ArgoCD 以 GitOps 方式管理集群自托管应用。所有配置以 Git 为单一事实来源，集群状态与仓库始终一致。

## 目录结构

```
gitops-base/
├── README.md
├── argocd/         ← Application CRD 定义（由 root App of Apps 自动管理）
│   ├── root.yaml                        → App of Apps（自动同步整个 argocd/ 目录）
│   ├── project.yaml                     → ArgoCD Project 定义
│   ├── metrics-server.yaml              → Helm: Metrics Server（kubectl top）
│   ├── victoria-metrics.yaml            → Helm: VM + node-exporter + kube-state-metrics + Grafana
│   ├── loki.yaml                        → Helm: Loki 日志聚合
│   ├── promtail.yaml                    → Helm: Promtail 日志采集
│   ├── cert-manager.yaml                → Helm: cert-manager（TLS 证书管理）
│   ├── cert-manager-resources.yaml      → ClusterIssuer / CA 资源
│   ├── gitea.yaml                       → Helm: Gitea
│   ├── kite.yaml                        → OCI Helm + raw service.yaml
│   └── kdebug.yaml                      → raw YAML manifests
└── apps/           ← 非 Helm 应用的原始 K8s 资源
    ├── cert-manager/
    │   └── cluster-issuer.yaml   ← 内部 CA (selfsigned → internal-ca)
    ├── kite/
    │   └── service.yaml
    └── kdebug/
        ├── namespace.yaml
        ├── deployment.yaml
        ├── service.yaml
        └── ingress.yaml          ← HTTPS via cert-manager ingress-shim
```

## 架构

### App of Apps 管理模式

```
root (argocd/root.yaml)
  └── 自动管理 argocd/ 下所有 Application
       ├── metrics-server          → kubelet / Pod 指标
       ├── victoria-metrics        → 监控 + Grafana
       ├── loki + promtail         → 日志聚合
       ├── cert-manager            → TLS 证书
       ├── cert-manager-resources  → 内部 CA
       ├── gitea                   → Git 服务
       ├── kite                    → OCI Helm + raw service
       └── kdebug                  → raw YAML (HTTPS ✓)
```

### 内部 PKI 体系

```
selfsigned-ca (ClusterIssuer)
  └── ca-root (Certificate) → secret: ca-root-secret
       └── internal-ca (ClusterIssuer)
            └── 各应用通过 ingress-shim 自动签发证书
```

### 分层说明

| 层级 | 目录 | 说明 |
|------|------|------|
| **Application 定义** | `argocd/` | ArgoCD Application CRD，指定来源、目标集群、同步策略 |
| **Helm 应用** | 内联在 `argocd/*.yaml` 的 `spec.source.helm.values` | 不单独存储 values 文件 |
| **raw 应用** | `apps/<name>/` | 直接 apply 的 K8s 资源文件，按资源类型拆分 |

## 前置条件

- 已安装 ArgoCD（参考 `bootstrap/` 或 infra-base 的安装脚本）
- `argocd` CLI 已登录集群
- 当前 kubeconfig 有权限管理目标命名空间

## 快速开始

```bash
# 一键部署所有基础设施（App of Apps 会自动管理所有子应用）
kubectl apply -f argocd/root.yaml

# 首次安装需等待 cert-manager 就绪后再同步证书资源
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/instance=cert-manager -n cert-manager --timeout=120s
kubectl annotate application cert-manager-resources -n argocd argocd.argoproj.io/refresh=true --overwrite
```

### 手动同步

ArgoCD 默认每 3 分钟自动检测 Git 变更并同步。如需立即生效：

```bash
argocd app sync kdebug
argocd app sync gitea
argocd app sync kite
```

### 添加新应用

**Helm 应用** — 在 `argocd/` 创建 Application yaml，values 内联：

```yaml
# argocd/myapp.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: myapp
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://example.com/charts
    chart: myapp
    targetRevision: 1.0.0
    helm:
      values: |
        replicaCount: 2
  destination:
    server: https://kubernetes.default.svc
    namespace: myapp
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

**raw YAML 应用** — 同上 + 在 `apps/<name>/` 下按资源类型拆分 manifests：

```
apps/myapp/
├── namespace.yaml
├── deployment.yaml
├── service.yaml
└── ingress.yaml
```

### 更新应用

1. 修改 Git 仓库中的配置
2. 提交并推送
3. ArgoCD 自动同步，或手动执行 `argocd app sync <name>`

## 校验

### 查看 ArgoCD 应用状态

```bash
# 应用列表及同步状态
argocd app list

# 查看单个应用详情
argocd app get kdebug

# 查看同步差异（dry-run）
argocd app diff kdebug
```

### 查看集群资源

```bash
# 确认资源已创建
kubectl get all -n kdebug

# 确认 Ingress 已就绪
kubectl get ingress -n kdebug

# 确认 ArgoCD Application 状态
kubectl get application -n argocd kdebug -o yaml | grep -E 'sync.status|health.status'
```

### 端到端验证

```bash
# 通过 Ingress 访问
curl -k https://kdebug.czw-sre.internal/ping

# 查看 Pod 日志
kubectl logs -n kdebug -l app=kdebug
```

## 清理

### 移除单个应用（保留 Git 仓库）

```bash
# 方法一：通过 ArgoCD CLI（推荐）
argocd app delete kdebug

# 方法二：通过 kubectl
kubectl delete -f argocd/kdebug.yaml
```

> 注意：`argocd app delete` 会级联删除集群中的资源（Deployment、Service、Ingress 等），但 Git 仓库中的文件保留。如需彻底移除，再手动删除仓库中的对应文件。

### 清理已删除应用的残留资源

如果某个应用从 Git 仓库中删除但集群中仍有残留：

```bash
# 检查 ArgoCD 中已删除或孤立的应用
argocd app list

# 手动清理残留资源
kubectl delete namespace kdebug
```

### 卸载所有应用

```bash
# 删除所有 Application（会级联删除其管理的资源）
kubectl delete -f argocd/

# 确认所有命名空间已清理
kubectl get ns | grep -E 'gitea|kite|kdebug'
```

## 应用清单

| 应用 | 安装方式 | 命名空间 | 域名 | 证书 |
|------|---------|----------|------|------|
| metrics-server | Helm (k8s-sigs) | kube-system | — | — |
| victoria-metrics | Helm (VM) | monitoring | grafana.czw-sre.internal | 待接入 internal-ca |
| loki + promtail | Helm (grafana) | loki | — | — |
| cert-manager | Helm (jetstack) | cert-manager | — | — |
| Gitea | Helm (gitea-charts) | gitea | gitea.czw-sre.internal | 待接入 internal-ca |
| Kite | OCI Helm (ghcr.io) + raw service | kite | kite.czw-sre.internal | 待接入 internal-ca |
| kdebug | raw YAML | kdebug | kdebug.czw-sre.internal | ✅ HTTPS (internal-ca) |

## 常见问题

### ArgoCD 同步卡在 Progressing

```bash
# 查看具体原因
argocd app get kdebug
argocd app logs kdebug

# 检查 Pod 是否拉取镜像中
kubectl describe pod -n kdebug -l app=kdebug
```

### 同步失败：OutOfSync

```bash
# 查看差异
argocd app diff kdebug

# 强制覆盖集群状态为 Git 状态
argocd app sync kdebug --force
```

### 如何避免误删

- ArgoCD Application 设置了 `prune: true`，删除 Application CRD 会级联删除其管理的所有资源
- 如需暂停同步但不删除资源：`argocd app set kdebug --sync-policy automated='{}'`
