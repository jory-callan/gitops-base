# victoria-metrics

通过 ArgoCD 部署的 [VictoriaMetrics K8s Stack](https://docs.victoriametrics.com/helm/victoriametrics-k8s-stack/)，
包含：

| 组件 | 说明 |
|------|------|
| VMSingle | Prometheus 兼容指标存储（单节点） |
| vmagent | 指标采集 |
| node-exporter | 节点指标 |
| kube-state-metrics | 集群状态指标 |
| Grafana | 仪表盘 + 告警 |

## 配置要点

- `vmsingle` 替代 `vmcluster`（小集群不需要集群模式）
- Grafana 已预装 VictoriaLogs 插件和数据源
- 禁用 `vmalert` / `vmalertmanager`（当前不启用告警）

## 访问

| 服务 | 地址 |
|------|------|
| Grafana | https://grafana.czw-sre.internal (admin/admin123) |
| VMSingle | `vmsingle-victoria-metrics-k8s-stack.monitoring.svc:8429` |
| vmagent | `vmagent-victoria-metrics-k8s-stack.monitoring.svc:8429` |

## 验证

```bash
# Grafana 是否运行
kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana

# 指标采集
kubectl port-forward -n monitoring svc/vmsingle-victoria-metrics-k8s-stack 8429:8429
# → curl http://localhost:8429/api/v1/query?query=up
```

## 踩坑

### Service 名超 63 字符

`victoria-metrics-victoria-metrics-k8s-stack-kube-controller-manager` 超长被拒绝。
该 service 为非关键组件（kube-controller-manager 端点），忽略不影响核心功能。
