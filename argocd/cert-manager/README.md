# cert-manager

通过 ArgoCD 部署的 [cert-manager](https://cert-manager.io/)，
用于自动化 TLS 证书管理。

## 配置要点

- 启用 CRD 安装（`crds.enabled: true`）
- 使用 ghcr.io/jetstack 镜像（通过内网 Nexus:5005 代理）

## 参考资料

- 内部 CA 配置见 `apps/cert-manager/cluster-issuer.yaml`
- 应用接入示例见 `apps/kdebug/ingress.yaml`（通过 annotation: `cert-manager.io/cluster-issuer: internal-ca`）
