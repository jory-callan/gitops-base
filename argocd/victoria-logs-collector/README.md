# victoria-logs-collector

通过 ArgoCD 部署的 [VictoriaLogs Collector](https://docs.victoriametrics.com/helm/victoria-logs-collector/)，
以 DaemonSet 形式在所有节点上采集容器日志并发送至 VictoriaLogs。

替换了原有的 Promtail。

## 配置要点

```yaml
remoteWrite:
  - url: http://victoria-logs-victoria-logs-single-server.victorialogs.svc:9428
```

- 自动采集 `/var/log/containers/*.log` 下的所有容器日志
- 自动添加 Kubernetes 元数据（namespace/pod/container/node）
- 资源使用极低（50m CPU / 64Mi 内存）

## 验证

```bash
kubectl get pods -n victorialogs -l app.kubernetes.io/name=victoria-logs-collector
kubectl logs -n victorialogs -l app.kubernetes.io/name=victoria-logs-collector --tail=3
```

## 踩坑

### Service 名称错误

第一次部署时填了 `victoria-logs.victorialogs.svc`，实际 service 名为
`victoria-logs-victoria-logs-single-server.victorialogs.svc`。

**排查：** `kubectl get svc -n victorialogs` 查看实际名称。

### remoteWrite 配置格式

第一次用了 `config.clients`（Promtail 风格），Collector chart 实际需要：

```yaml
remoteWrite:
  - url: http://...
```
