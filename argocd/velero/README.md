# velero

通过 ArgoCD 部署的 [Velero](https://velero.io/) 集群备份工具。

## 配置要点

- 后端：MinIO S3（bucket: `velero`）
- 凭证：复用 MinIO root 凭证（`minioadmin/minioadmin`）
- 备份策略：每天凌晨 2 点全量资源备份，保留 7 天
- 快照：关闭（NFS 不支持 CSI 快照，仅做 K8s 资源备份）
- 排除：kube-system、kube-public、kube-node-lease

## 日常操作

```bash
# 查看备份状态
velero backup get

# 手动触发备份
velero backup create manual-$(date +%Y%m%d)

# 查看备份详情
velero backup describe daily-backup-<timestamp>

# 模拟恢复（不实际恢复）
velero restore create --from-backup <backup-name> --dry-run

# 恢复特定 namespace
velero restore create --from-backup <backup-name> --include-namespaces kdebug

# 查看定时任务
velero schedule get
```

## 踩坑

- NFS 存储类不支持 CSI 快照，`snapshotsEnabled: false`
- 恢复 PVC 时需要手动创建同名的 NFS PV，否则 Pod 无法绑定
- MinIO 单节点故障会导致 Velero 备份不可用，建议优先保障 MinIO 稳定
