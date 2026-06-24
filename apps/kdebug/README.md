# kdebug

调试 Pod 应用的原始 K8s 资源。

## 文件

| 文件 | 说明 |
|------|------|
| namespace.yaml | kdebug 命名空间 |
| deployment.yaml | 运行 ghcr.io/jory-callan/kdebug:v1.0.2 |
| service.yaml | ClusterIP :80 → :8080 |
| ingress.yaml | HTTPS via cert-manager internal-ca |

## HTTPS 说明

Ingress 通过 annotation `cert-manager.io/cluster-issuer: internal-ca` 自动签发证书，
secret 名 `kdebug-tls`。证书链：

```
selfsigned-ca → ca-root → internal-ca → kdebug-tls
```

## 验证

```bash
curl -k https://kdebug.czw-sre.internal/ping
```
