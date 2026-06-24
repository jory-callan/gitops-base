# gitea

通过 ArgoCD 部署的 [Gitea](https://gitea.com/) Git 服务。

## 配置要点

- 使用 Gitea 官方 Helm chart
- 使用 NFS 持久化 10Gi
- SQLite 作为数据库（轻量，适合小集群）
- ingress: gitea.czw-sre.internal

## 访问

https://gitea.czw-sre.internal

## 待办

- [ ] 接入 internal-ca 证书
