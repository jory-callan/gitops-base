# victoria-logs

通过 ArgoCD 部署的 [VictoriaLogs](https://docs.victoriametrics.com/victorialogs/)
单节点日志存储服务。替换了原有的 Loki。

## 为什么换掉 Loki

| 对比 | Loki | VictoriaLogs |
|------|------|-------------|
| 内存 | ~2Gi + memcached | ~256Mi |
| 压缩 | 2-5x | 10-30x |
| 部署 | gateway + ingester + cache + ... | 单 Pod |

详见 `archive/loki/README.md`。

## 配置要点

- 保留 7 天日志
- 使用 NFS 持久化 10Gi
- HTTP API: `victoria-logs-victoria-logs-single-server.victorialogs.svc:9428`

## 验证

```bash
# 查询所有日志（最近 5 条）
kubectl run -q --rm -i --restart=Never tmp --image=curlimages/curl \
  -- curl "http://victoria-logs-victoria-logs-single-server.victorialogs.svc:9428/select/logsql/query?query=*&limit=5"

# 查看存储状态
kubectl logs victoria-logs-victoria-logs-single-server-0 -n victorialogs --tail=3
```
