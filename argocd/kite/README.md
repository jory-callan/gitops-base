# kite

通过 ArgoCD 部署的 [Kite](https://kite.com/)（OCI Helm + 自定义 service）。

## 配置要点

- 双来源：OCI Helm chart + `apps/kite/service.yaml`
- Helm chart 从 ghcr.io/kite-org/charts 拉取（验证是否可访问）
- 使用 sqlite + NFS 持久化

## 当前问题

**OCI chart 拉取失败：** 国内网络无法稳定访问 ghcr.io OCI registry。
持续关注上游修复。

## 访问

https://kite.czw-sre.internal
