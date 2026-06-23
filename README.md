# gitops-base — ArgoCD GitOps 应用管理

通过 ArgoCD 声明式管理集群自托管应用。

```
gitops-base/
├── README.md
├── argocd/       ← Application 定义（每个应用一个 yaml，ArgoCD root 直接同步此目录）
│   ├── gitea.yaml
│   ├── kite.yaml
│   └── kdebug.yaml
└── apps/         ← 原始 K8s 资源（非 Helm 应用的 manifests）
    ├── kite/
    │   └── service.yaml
    └── kdebug/
        ├── namespace.yaml
        ├── deployment.yaml
        ├── service.yaml
        └── ingress.yaml
```

## 初始化

```bash
kubectl apply -f argocd/kite.yaml  # 先安装 ArgoCD 可管理的应用，按需选择
# 或安装所有：
kubectl apply -f argocd/
```

## 应用清单

| 应用 | 安装方式 | 命名空间 | 访问 |
|------|---------|----------|------|
| Gitea | Helm (gitea-charts) | gitea | gitea.czw-sre.internal |
| Kite | OCI Helm (ghcr.io) + service.yaml | kite | kite.czw-sre.internal / NodePort:30301 |
| kdebug | raw YAML | kdebug | kdebug.czw-sre.internal |

## 添加新应用

- **Helm 应用**：在 `argocd/` 创建 yaml，values 内联
- **raw YAML 应用**：同上 + 在 `apps/` 下放资源文件
