# gitops-base — GitOps 集群管理 (ArgoCD)

通过 ArgoCD 管理所有集群组件的声明式配置。

与 [infra-base](https://github.com/jory-callan/infra-base) 的关系：

```
infra-base          ← 裸机到集群：Ansible + bootstrap 脚本，一次性搭建
gitops-base         ← 运行态管理：ArgoCD 声明式运维，持续同步
```

## 架构

```yaml
gitops-base/
├── README.md
├── .gitignore
└── clusters/
    └── czw-sre/                 # 集群名称（支持多集群）
        ├── root.yaml            # App of Apps — 入口
        ├── infrastructure/      # 基础设施组件
        │   ├── kustomization.yaml
        │   ├── cilium.yaml      # CNI 网络
        │   ├── metallb.yaml     # LoadBalancer
        │   ├── ingress-nginx.yaml  # Ingress Controller
        │   └── nfs.yaml         # NFS StorageClass
        └── applications/        # 自托管应用
            ├── kustomization.yaml
            ├── gitea.yaml       # Git 服务
            └── kite.yaml        # K8s Web UI
```

## 使用方式

### 初始化（首次）

```bash
# 将本仓库添加到 ArgoCD
kubectl apply -f clusters/czw-sre/root.yaml
```

### 添加新组件

```bash
# 1. 创建 Application YAML
cat > clusters/czw-sre/infrastructure/my-component.yaml <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-component
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/jory-callan/gitops-base
    targetRevision: HEAD
    path: charts/my-component
  destination:
    server: https://kubernetes.default.svc
    namespace: my-namespace
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

# 2. 更新 kustomization.yaml 加入新文件
# 3. 提交推送，ArgoCD 自动同步 root App
```

### 卸载组件

从 kustomization.yaml 中移除文件路径，提交推送，ArgoCD 自动清理。

## 设计原则

1. **单一真相源** — 集群的所有状态声明在 git 中，ArgoCD 保证集群与 git 一致
2. **App of Apps** — root Application 管理所有子 Application，kustomize 组织
3. **values 就近** — 每个 Application 的 values 内联在 YAML 中，或者引用 `clusters/czw-sre/values/` 下的共享配置
4. **自修复** — 所有 Application 开启 `selfHeal: true`，手动修改会被 ArgoCD 还原
5. **按集群分层** — `clusters/<cluster-name>/` 支持多集群管理
