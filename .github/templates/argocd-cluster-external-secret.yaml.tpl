apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: __CLUSTER_NAME__
  namespace: argocd
spec:
  refreshInterval: 5m
  secretStoreRef:
    name: argocd-clusters-store
    kind: ClusterSecretStore
  target:
    name: __CLUSTER_NAME__
    template:
      metadata:
        labels:
          argocd.argoproj.io/secret-type: cluster
          role: spoke
      data:
        name: "{{ .name }}"
        server: "{{ .server }}"
        config: |
          {"bearerToken":"{{ .token }}","tlsClientConfig":{"insecure":false,"caData":"{{ .caData }}"}}
  dataFrom:
    - extract:
        key: argocd-clusters/__CLUSTER_NAME__