# kdebug

通过 ArgoCD 部署的调试 Pod，用于验证集群网络、Ingress、证书等工作正常。

## 组件

| 资源 | 说明 |
|------|------|
| Namespace | kdebug |
| Deployment | ghcr.io/jory-callan/kdebug:v1.0.2, replicas: 2 |
| Service | ClusterIP :80 → :8080 |
| Ingress | kdebug.czw-sre.internal (HTTPS) |
| HPA | CPU 70%, min 2 / max 5 |
| PDB | minAvailable: 1 |

## 稳定性配置（7 层框架）

| 层级 | 配置 |
|------|------|
| 资源层 | request: 50m/32Mi, limit: 128Mi memory（CPU limit 不设） |
| 扩缩容 | HPA CPU 70%, 2~5 副本 |
| 保护层 | PDB minAvailable: 1 |
| 分布层 | podAntiAffinity (hostname) + topologySpread (zone) |
| 健康层 | startupProbe → livenessProbe + readinessProbe |
| 退出层 | terminationGracePeriodSeconds: 30 + preStop sleep 5s |

## 验证

```bash
# HTTPS 访问
curl -k https://kdebug.czw-sre.internal/ping
```

## 踩坑

### 镜像 tag 不存在

将 `v1.0.0` 升到 `v1.0.1` 时，先验证了镜像在 ghcr.io 是否存在。
**建议：** 升级前先 `curl` 检查 tag。
