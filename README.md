# gitops-base — GitOps 应用管理 (ArgoCD)

通过 ArgoCD 管理集群上所有自托管应用的声明式配置。

与 [infra-base](https://github.com/jory-callan/infra-base) 的关系：

```
infra-base          ← 裸机到集群：Ansible + bootstrap 脚本
  ├── bootstrap/    ← 基础设施 (Cilium/MetalLB/ingress-nginx/NFS)，手动安装一次
  └── apps/         ← 应用安装脚本 (Gitea/Kite)

gitops-base         ← 运行态管理：ArgoCD 声明式持续同步
  └── applications/ ← 应用期望状态
```

> 基础设施组件（Cilium、MetalLB、ingress-nginx、NFS）不由 GitOps 管理，
> 因为它们是 ArgoCD 自身的网络和入口依赖，避免鸡生蛋问题。

## 架构

```
root.yaml (手动 apply)
  │
  ▼
ArgoCD sync ── Kustomize ──+
                            │
               ┌────────────┼────────────┐
               ▼            ▼            ▼
           gitea.yaml   kite.yaml   kite-nodeport.yaml
               │            │            │
               ▼            ▼            ▼
           Gitea Pod    Kite Pod    NodePort:30301
           (Helm)      (OCI Helm)   (raw YAML)
```

## 使用方式

### 初始化

```bash
kubectl apply -f root.yaml
```

### 添加新应用

```bash
# 1. 创建 Application YAML
cat > clusters/czw-sre/applications/my-app.yaml <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/jory-callan/gitops-base
    targetRevision: HEAD
    path: clusters/czw-sre/applications/my-app
  destination:
    server: https://kubernetes.default.svc
    namespace: my-app
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

# 2. 在 kustomization.yaml 中加入新文件
# 3. 提交推送，ArgoCD 自动同步
```

## 结构

```
gitops-base/
├── README.md
├── root.yaml                          ← App of Apps（手动 apply）
└── clusters/
    └── czw-sre/
        ├── kustomization.yaml         ← 聚合 applications/
        └── applications/
            ├── kustomization.yaml
            ├── gitea.yaml             → Helm: gitea-charts/gitea
            ├── kite.yaml              → OCI: ghcr.io/kite-org/charts/kite
            └── kite-nodeport.yaml     → raw YAML: NodePort:30301
```

## 当前管理的应用

| 应用 | 安装方式 | 命名空间 | 域名 |
|------|---------|----------|------|
| Gitea | Helm (gitea-charts) | gitea | gitea.czw-sre.internal |
| Kite | OCI Helm (ghcr.io) | kite | kite.czw-sre.internal |
| Kite NodePort | raw YAML | kite | —（NodePort:30301） |
| kdebug | raw YAML | kdebug | kdebug.czw-sre.internal |

## 设计原则

1. **只管应用** — 基础设施组件 bootstrap 管理，不纳入 GitOps
2. **App of Apps** — root Application 管理所有子 Application
3. **values 内联** — Helm values 写在 Application 的 helm.values 字段中
4. **自修复** — 所有 Application 开启 `selfHeal: true`
5. **多集群就绪** — `clusters/<name>/` 分层，支持多集群
