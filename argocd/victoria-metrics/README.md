# victoria-metrics

通过 ArgoCD 部署的 [VictoriaMetrics K8s Stack](https://docs.victoriametrics.com/helm/victoriametrics-k8s-stack/)，
包含：

| 组件 | 说明 |
|------|------|
| VMSingle | Prometheus 兼容指标存储（单节点） |
| vmagent | 指标采集（自动发现 VMServiceScrape） |
| node-exporter | 节点指标 |
| kube-state-metrics | 集群状态指标 |
| Grafana | 仪表盘 + 告警 |

## 配置要点

- `vmsingle` 替代 `vmcluster`（小集群不需要集群模式）
- Grafana 已预装 VictoriaLogs 插件和数据源
- 禁用 `vmalert` / `vmalertmanager`（当前不启用告警）
- **已启用 prometheus-operator CRD 兼容**（见下方 ServiceMonitor 章节）

## 应用指标采集对接

### 方式一：Prometheus ServiceMonitor（推荐，已兼容）

VictoriaMetrics Operator 已启用 prometheus-operator CRD 转换器（`disable_prometheus_converter: false`），
会自动将 `servicemonitors.monitoring.coreos.com` CRD 转换为 VMServiceScrape 并采集指标。

**前置：** `servicemonitors.monitoring.coreos.com` 和 `podmonitors.monitoring.coreos.com` CRD 已在集群中安装。

**示例（在你的应用 namespace 中）：**

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: myapp
  namespace: myapp
spec:
  namespaceSelector:
    matchNames:
      - myapp
  selector:
    matchLabels:
      app: myapp
  endpoints:
    - port: metrics
      path: /metrics
      interval: 15s
```

创建后 VictoriaMetrics Operator 会自动将其转为 VMServiceScrape，vmagent 自动发现并抓取。

### 方式二：VictoriaMetrics VMServiceScrape（原生格式）

```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMServiceScrape
metadata:
  name: myapp
  namespace: myapp
spec:
  namespaceSelector:
    matchNames:
      - myapp
  selector:
    matchLabels:
      app: myapp
  endpoints:
    - port: metrics
      path: /metrics
      interval: 15s
```

### 方式三：VMAgent inlineScrapeConfig（无需 CRD）

适合不想 CRD 的场景：

```yaml
# 在 victoria-metrics values.yaml 中配置
vmagent:
  spec:
    inlineScrapeConfig: |
      - job_name: myapp
        kubernetes_sd_configs:
          - role: endpoints
            namespaces:
              names: [myapp]
        relabel_configs:
          - source_labels: [__meta_kubernetes_service_label_app]
            regex: myapp
            action: keep
```

### 验证指标是否被采集

```bash
# 查看 VMAgent 发现的目标
kubectl port-forward -n monitoring svc/vmagent-victoria-metrics-k8s-stack 8429:8429
# → http://localhost:8429/targets   （Web 页面，查看采集目标状态）
# → http://localhost:8429/api/v1/query?query=up   （查询所有 up 指标）
```

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

# ServiceMonitor CRD 是否生效
kubectl get crd servicemonitors.monitoring.coreos.com

# 指标采集 - 通过 VMSingle 查询
kubectl port-forward -n monitoring svc/vmsingle-victoria-metrics-k8s-stack 8429:8429
# → curl http://localhost:8429/api/v1/query?query=up

# 查看 VMAgent 已发现的目标
kubectl port-forward -n monitoring svc/vmagent-victoria-metrics-k8s-stack 8429:8429
# → http://localhost:8429/targets
```

## 踩坑

### Service 名超 63 字符

`victoria-metrics-victoria-metrics-k8s-stack-kube-controller-manager` 超长被拒绝。
该 service 为非关键组件（kube-controller-manager 端点），忽略不影响核心功能。
