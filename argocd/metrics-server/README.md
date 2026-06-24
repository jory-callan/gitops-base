# metrics-server

通过 ArgoCD 部署的 Kubernetes [Metrics Server](https://github.com/kubernetes-sigs/metrics-server)，
为 `kubectl top` 和 HPA 提供资源指标。

## 配置要点

```yaml
args:
  - --kubelet-insecure-tls   # k3s 自签名证书需要
```

## 验证

```bash
kubectl top nodes
kubectl top pods -A
```

## 踩坑

### 旧 Deployment 冲突

首次用 ArgoCD 接管时，如果集群已有 bootstrap 安装的 metrics-server，
`spec.selector` 不可变导致同步失败。

**解决：** `kubectl delete deployment metrics-server -n kube-system`，让 ArgoCD 重新创建。

### API 未就绪

删除旧 Deployment 后还需清理旧的 APIService，否则新 Pod 注册不上：

```bash
kubectl delete apiservice v1beta1.metrics.k8s.io
```

ArgoCD 会自动重建。
