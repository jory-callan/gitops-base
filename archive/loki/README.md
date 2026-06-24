# Loki + Promtail — 归档说明

## 为什么选择 Loki（历史）

最初选择了 Grafana Loki 作为日志聚合方案，因为它：
- 社区成熟，文档丰富
- 原生 Grafana 集成
- 标签索引机制

## 为什么切换到 VictoriaLogs

| 对比项 | Loki | VictoriaLogs |
|--------|------|-------------|
| 架构复杂度 | 多组件（gateway/distributor/ingester/cache...） | 单二进制 |
| 资源占用 | 默认 memcached 请求 9.8Gi 内存 | 256Mi 起步 |
| 磁盘压缩 | 2-5x | 10-30x |
| 部署体验 | validate.yaml 各种陷阱 | 开箱即用 |

踩坑记录详见根目录 README。

## 如何恢复

如需切回 Loki：

```bash
# 1. 删除 VictoriaLogs 相关
kubectl delete application victoria-logs -n argocd --cascade=orphan
kubectl delete application victoria-logs-collector -n argocd --cascade=orphan

# 2. 重新部署 Loki
kubectl apply -f archive/loki/application.yaml
kubectl apply -f archive/loki/promtail-application.yaml
```
