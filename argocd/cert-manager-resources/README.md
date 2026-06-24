# cert-manager-resources

通过 ArgoCD 管理的内部 PKI 资源。

## 结构

```
selfsigned-ca (ClusterIssuer)
  └── ca-root-secret (Certificate)
       └── internal-ca (ClusterIssuer)
            └── 应用通过 ingress-shim 自动签发证书
```

## 应用接入

在 Ingress 上加 annotations 即可：

```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: internal-ca
spec:
  tls:
    - hosts:
        - <your>.czw-sre.internal
      secretName: <name>-tls
```

## 验证

```bash
kubectl get clusterissuer
kubectl get certificate -A
```

## 踩坑

### 引用 internal-ca 时需 etcd 已就绪

如果 cert-manager 还没部署完成就应用 ClusterIssuer，
ArgoCD 会报错（CRD 不存在），等 cert-manager 就绪后自动恢复。
