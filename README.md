# gitops-base — ArgoCD GitOps 应用管理

通过 ArgoCD 以 GitOps 方式管理 k3s 集群自托管应用。所有配置以 Git 为单一事实来源，集群状态与仓库始终一致。

## 目录结构

```
gitops-base/
├── README.md
├── archive/                    ← 已退役组件的历史配置（保留作为参考和回退方案）
│   └── loki/                   ← Loki + Promtail（已替换为 VictoriaLogs）
│       ├── README.md
│       ├── application.yaml          ← 原 argocd/loki.yaml
│       ├── promtail-application.yaml ← 原 argocd/promtail.yaml
│       ├── loki-community-6.32.0.tgz
│       └── promtail-6.16.6.tgz
│
├── argocd/                     ← Application CRD 定义（由 root App of Apps 自动管理）
│   ├── root.yaml               → App of Apps（自动同步整个 argocd/ 目录）
│   ├── project.yaml            → ArgoCD Project 定义
│   ├── metrics-server.yaml     → Helm: Metrics Server（kubectl top / HPA）
│   ├── victoria-metrics.yaml   → Helm: VMSingle + node-exporter + kube-state-metrics + Grafana
│   ├── victoria-logs.yaml      → Helm: VictoriaLogs 日志存储（替换 Loki）
│   ├── victoria-logs-collector.yaml  → Helm: 日志采集 DaemonSet（替换 Promtail）
│   ├── cert-manager.yaml       → Helm: cert-manager（TLS 证书管理）
│   ├── cert-manager-resources.yaml   → ClusterIssuer / 内部 CA
│   ├── gitea.yaml              → Helm: Gitea
│   ├── kite.yaml               → OCI Helm + raw service.yaml
│   └── kdebug.yaml             → raw YAML manifests
│
├── apps/                       ← 非 Helm 应用的原始 K8s 资源
│   ├── cert-manager/
│   │   └── cluster-issuer.yaml     ← 内部 CA (selfsigned → internal-ca)
│   └── kdebug/
│       ├── namespace.yaml
│       ├── deployment.yaml
│       ├── service.yaml
│       └── ingress.yaml            ← HTTPS via cert-manager ingress-shim
│
└── .gitignore
```

## 架构

### App of Apps 管理模式

```
root (argocd/root.yaml)
  └── 自动管理 argocd/ 下所有 Application
       ├── metrics-server          → kubelet / Pod 指标
       ├── victoria-metrics        → 监控 + Grafana
       ├── victoria-logs + collector → 日志聚合（VictoriaMetrics 生态）
       ├── cert-manager            → TLS 证书
       ├── cert-manager-resources  → 内部 CA
       ├── gitea                   → Git 服务
       ├── kite                    → OCI Helm + raw service
       └── kdebug                  → raw YAML (HTTPS ✓)
```

### 内部 PKI 体系

```
selfsigned-ca (ClusterIssuer)
  └── ca-root (Certificate) → secret: ca-root-secret
       └── internal-ca (ClusterIssuer)
            └── 各应用通过 ingress-shim 自动签发证书
```

### 技术栈总览

| 领域 | 方案 | 说明 |
|------|------|------|
| 集群 | k3s | 3 节点 (2C8G40G) |
| 网络 | Cilium + MetalLB | |
| GitOps | ArgoCD v2.14 | App of Apps 模式 |
| 指标 | VictoriaMetrics (VMSingle) + vmagent | 替代 Prometheus（省资源） |
| 日志 | VictoriaLogs + Collector | 替代 Loki（省 10x 空间） |
| 证书 | cert-manager + 内部 CA | 自签名 CA，自动签发 |
| 存储 | NFS (nfs-client) | PVC 动态供给 |
| Ingress | ingress-nginx | |
| 镜像 | 192.168.5.103:5xxx | Nexus 镜像代理（ghcr/quay/k8s等） |
| Helm | 192.168.5.103:8081 | Nexus Helm 托管仓库 |

## 前置条件

- 已安装 ArgoCD（由 bootstrap 层安装，见 infra-base 仓库）
- kubeconfig 已配置（`~/.kube/config-infra-base`）
- `kubectl` 可直接操作集群

## 快速开始

```bash
# 一键部署所有应用
kubectl apply -f argocd/root.yaml

# 查看部署状态
kubectl get application -n argocd -w
```

## 应用清单

| 应用 | 方式 | 命名空间 | 域名 | 证书 |
|------|------|---------|------|------|
| metrics-server | Helm | kube-system | — | — |
| victoria-metrics | Helm | monitoring | grafana.czw-sre.internal | 待接入 |
| victoria-logs | Helm | victorialogs | — | — |
| cert-manager | Helm | cert-manager | — | — |
| Gitea | Helm | gitea | gitea.czw-sre.internal | 待接入 |
| Kite | OCI Helm | kite | kite.czw-sre.internal | 待接入 |
| kdebug | raw YAML | kdebug | kdebug.czw-sre.internal | ✅ HTTPS |

## 运维指南

### 常用命令

```bash
# 查看应用状态
kubectl get application -n argocd -o wide

# 手动触发同步
kubectl annotate application <name> -n argocd argocd.argoproj.io/refresh=true --overwrite

# 查看节点资源
kubectl top nodes

# 查看 Pod 资源
kubectl top pods -A

# 查询日志（VictoriaLogs）
kubectl run -q --rm -i --restart=Never tmp --image=curlimages/curl \
  -- curl "http://victoria-logs-victoria-logs-single-server.victorialogs.svc:9428/select/logsql/query?query=*&limit=5"

# Grafana 管理
# URL:   https://grafana.czw-sre.internal
# Admin: admin / admin123

# 查看 Helm charts 来源
curl -s http://192.168.5.103:8081/repository/helm-hosted/index.yaml | head
```

### 添加新应用

1. **Helm 应用**：在 `argocd/` 创建 Application yaml，Helm values 内联
2. **raw YAML 应用**：同上 + 在 `apps/<name>/` 放 K8s 资源文件
3. 提交并推送至 GitHub
4. root App of Apps 自动检测并同步

### 应用生命周期

```bash
# 暂停自动同步
kubectl patch application <name> -n argocd --type merge \
  -p='{"spec":{"syncPolicy":null}}'

# 恢复自动同步
kubectl patch application <name> -n argocd --type merge \
  -p='{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'

# 移除应用（保留集群资源）
kubectl delete application <name> -n argocd --cascade=orphan

# 彻底删除
kubectl delete -f argocd/<name>.yaml
```

## 踩坑记录

> 以下所有问题均真实发生在此项目中，记录以便复现时快速定位。

### 1. Loki memcached 默认请求 9.8Gi 内存

**现象：** `loki-chunks-cache-0` 一直 Pending
**原因：** Loki Helm chart 默认 `chunksCache.allocatedMemory: 8192MB`，memcached 容器请求 9.8Gi，远超节点 7.8Gi 容量
**解决：** `chunksCache.enabled: false`（小集群不需要缓存层），或 `allocatedMemory: 256`
**教训：** 生产级 Helm chart 的默认值通常面向大型集群，部署前务必检查资源请求

### 2. Loki validate.yaml 校验陷阱

**现象：** `"You have more than zero replicas configured for both the single binary and simple scalable targets"`
**原因：** Loki chart 的 `validate.yaml` 检查到 `singleBinary.replicas=1`（我设的）和 `backend.replicas=3` / `read.replicas=3` / `write.replicas=3`（chart 默认值）
**解决：** 显式将所有不需要的组件 replica 设为 0
```yaml
backend:
  replicas: 0
read:
  replicas: 0
write:
  replicas: 0
```
**教训：** Loki chart 默认值同时启用 SingleBinary 和 SimpleScalable 的 replicas，必须显式覆盖

### 3. VictoriaMetrics k8s-stack 服务名超长

**现象：** `"Service ... kube-controller-manager is invalid: must be no more than 63 characters"`
**原因：** VM chart 生成的 service 名称超过 Kubernetes 63 字符限制
**影响：** 仅 kube-controller-manager 端点不可用，其他组件（Grafana, VMSingle, vmagent, node-exporter）全正常
**解决：** 不影响核心功能，可忽略。如需修复需加 `fullnameOverride` 缩短前缀
**教训：** 资源名拼接过长时需考虑 63 字符限制

### 4. cert-manager 安装卡住

**现象：** ArgoCD 同步卡在 Progressing，Pod 在 ContainerCreating
**原因：** 国内网络无法拉取 ghcr.io/jetstack/cert-manager-controller 镜像
**解决：** 配置 containerd registry mirror，301 指向内网 Nexus（port 5005=ghcr.io）
**教训：** 国内环境必须预先配好镜像代理

### 5. Helm chart GitHub Pages 不可达

**现象：** `helm pull ... timeout after 1m30s`
**原因：** `charts.jetstack.io` / `kubernetes-sigs.github.io` / `victoriametrics.github.io` / `grafana.github.io` 均为 GitHub Pages，国内不可达
**解决：** 下载 chart 到本地 → 推送至内网 Nexus Helm 托管仓库 → ArgoCD 指向内网
```bash
# 下载 chart
curl -sL "https://gh-proxy.com/https://github.com/.../chart.tgz" -o /tmp/chart.tgz

# 推送至 Nexus
curl -X POST "http://192.168.5.103:8081/service/rest/v1/components?repository=helm-hosted" \
  -F "helm.asset=@/tmp/chart.tgz"
```
**教训：** 在中国运维 K8s，内网制品仓库是必须的基础设施

### 6. Grafana 插件安装慢/失败（国内网络）

**现象：** Grafana Pod 2/3 Ready 卡住，Readiness probe 失败
**原因：** `GF_INSTALL_PLUGINS=victoriametrics-logs-datasource` 下载慢，Grafana 在插件下载完成前不监听端口
**解决：** 改用 `GF_PLUGINS_PREINSTALL`（兼容新版 Grafana），增加 liveness probe 的 `initialDelaySeconds`
```yaml
# VM k8s-stack values
grafana:
  plugins:
    - victoriametrics-logs-datasource
```
**教训：** `GF_INSTALL_PLUGINS` 已废弃，用 `GF_PLUGINS_PREINSTALL` 或 chart 的 `plugins` 配置

### 7. Helm OCI 不可用（中国网络）

**现象：** `kite` 应用 `"oci://ghcr.io/kite-org/charts" is not a valid chart repository`
**原因：** ghcr.io OCI 仓库在国内不稳定
**解决：** 该问题为 kite 上游 chart 问题，持续关注
**教训：** OCI Helm charts 在受限网络环境中可靠性不如传统 Helm repo

### 8. metrics-server 新旧 Deployment 冲突

**现象：** `Deployment.apps "metrics-server" is invalid: spec.selector: field is immutable`
**原因：** 之前通过 bootstrap 手动安装的 metrics-server Deployment 与新 ArgoCD 管理的 Deployment selector 不同
**解决：** `kubectl delete deployment metrics-server -n kube-system` → 让 ArgoCD 重新创建
**教训：** ArgoCD 接管已有资源前，需先清理旧资源

### 9. Nexus 匿名上传权限

**现象：** upload chart 时报 `401 Unauthorized` 或 `Not authorized`
**原因：** Nexus 默认要求认证，匿名用户无上传权限
**解决：** 在 Nexus 后台设置 `Security > Privileges` 允许 anonymous 用户上传
**教训：** 私有仓库的读写权限分离配置

## 设计决策

### 为什么用 VictoriaMetrics 而非 Prometheus

| | Prometheus | VictoriaMetrics |
|---|---|---|
| 资源 | 默认 512Mi+，频繁 OOM | 256Mi 可运行 |
| 存储 | 本地磁盘，缺乏压缩 | 10x+ 压缩比（适合 40G 系统盘） |
| 高可用 | Thanos/Cortex 额外组件 | VMCluster 原生支持 |
| 运维 | 配置复杂，调优经验要求高 | 开箱即用 |

### 为什么用 VictoriaLogs 而非 Loki

同上——资源占用和压缩比差距显著。详见 `archive/loki/README.md`。

### 为什么用内部 CA 而非 Let's Encrypt

- 所有域名均为 `*.czw-sre.internal` 内网域名
- 国内 Let's Encrypt 访问不稳定
- 自签名 CA 更适合内部 PKI

### 为什么用 Nexus 而非 Harbor

- 已有 Nexus 基础设施
- 同时支持 Docker registry + Helm 托管仓库
- 单实例运维简单

## 故障排查

### ArgoCD 不同步

```bash
# 查看错误信息
kubectl get application <name> -n argocd -o jsonpath='{.status.conditions[0].message}'

# 刷新
kubectl annotate application <name> -n argocd argocd.argoproj.io/refresh=true --overwrite

# 重启 repo-server（Helm chart 缓存问题）
kubectl rollout restart -n argocd deploy/argocd-repo-server

# 检查 repo-server 日志
kubectl logs -n argocd deploy/argocd-repo-server --tail=50
```

### Pod 拉取镜像失败

```bash
# 检查镜像代理是否可用
curl -s http://192.168.5.103:5005/v2/_catalog

# 检查 containerd mirror 配置
kubectl get nodes -o yaml | grep -A5 registry-mirrors

# 手动测试拉取
kubectl run -it --rm test --image=curlimages/curl -- sh
```

### VictoriaLogs 查不到数据

```bash
# 检查 collector 是否正常运行
kubectl get pods -n victorialogs
kubectl logs -n victorialogs -l app.kubernetes.io/name=victoria-logs-collector --tail=5

# 检查 VictoriaLogs 存储状态
kubectl logs -n victorialogs victoria-logs-victoria-logs-single-server-0 --tail=3

# 直接查询
kubectl run -q --rm -i --restart=Never tmp --image=curlimages/curl \
  -- curl "http://victoria-logs-victoria-logs-single-server.victorialogs.svc:9428/select/logsql/query?query=*&limit=3"
```
