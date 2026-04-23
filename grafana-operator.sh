#!/usr/bin/env bash
set -euo pipefail

# 1. Create ConfigMap to enable user workload monitoring
oc apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
    prometheusK8s:
      volumeClaimTemplate:
        spec:
          resources:
            requests:
              storage: 10Gi
    alertmanagerMain:
      volumeClaimTemplate:
        spec:
          resources:
            requests:
              storage: 5Gi
EOF

# 2. Create Grafana project
oc get project grafana &>/dev/null || { oc new-project grafana >/dev/null && echo "project.project.openshift.io/grafana created"; }

# 3. Create service account with OAuth redirect annotation
oc apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: grafana-sa
  namespace: grafana
  annotations:
    # Registers the Grafana Route as the valid OAuth redirect URI for this SA
    serviceaccounts.openshift.io/oauth-redirectreference.grafana: '{"kind":"OAuthRedirectReference","apiVersion":"v1","reference":{"kind":"Route","name":"grafana-route"}}'
EOF

# 4. Grant cluster-monitoring-view role to service account
oc apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: grafana-sa-cluster-monitoring-view
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-monitoring-view
subjects:
- kind: ServiceAccount
  name: grafana-sa
  namespace: grafana
EOF

# 5. Grant auth-delegator so the oauth-proxy can validate tokens with the OpenShift API
oc apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: grafana-sa-auth-delegator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
- kind: ServiceAccount
  name: grafana-sa
  namespace: grafana
EOF

# 6. Create session secret for oauth-proxy cookie encryption
oc create secret generic grafana-proxy-session-secret \
  --from-literal=session_secret=$(head -c 43 /dev/urandom | base64) \
  -n grafana \
  --dry-run=client -o yaml | oc apply --server-side -f -

# 7. Create long-lived SA token secret for Prometheus authentication
oc apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: grafana-sa-token
  namespace: grafana
  annotations:
    kubernetes.io/service-account.name: grafana-sa
type: kubernetes.io/service-account-token
EOF

# Wait for token to be populated
sleep 5

# 8. Sync prometheus-credentials secret with the current SA token
TOKEN=$(oc -n grafana get secret grafana-sa-token --template='{{ .data.token | base64decode }}')
oc create secret generic prometheus-credentials \
  --from-literal=PROMETHEUS_TOKEN="Bearer $TOKEN" \
  -n grafana \
  --dry-run=client -o yaml | oc apply --server-side -f -

# 9. Add Grafana Helm repo and install Grafana Operator
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
helm upgrade -i grafana-operator grafana/grafana-operator \
  --version 5.22.2 \
  --namespace grafana \
  --set isOpenShift=true \
  --set namespaceScope=true \
  --set watchNamespaces="grafana"

kubectl apply -k grafana/

echo "Waiting for Grafana Operator to be ready..."
sleep 60

# 10. Print the Grafana route
ROUTE=$(oc -n grafana get route grafana-route -o jsonpath='{.spec.host}')
echo -e "\nGrafana is available at: https://$ROUTE\n"

echo "Day 0 bootstrap complete."


# # 1. Remove Grafana operator CRs
# kubectl delete -k grafana/ --ignore-not-found

# # 2. Uninstall Grafana Operator Helm release
# helm uninstall grafana-operator -n grafana

# # 3. Remove cluster-scoped RBAC
# oc delete clusterrolebinding grafana-sa-cluster-monitoring-view --ignore-not-found
# oc delete clusterrolebinding grafana-sa-auth-delegator --ignore-not-found

# # 4. Delete the grafana namespace (removes all namespaced resources with it)
# oc delete project grafana --ignore-not-found

# # 5. Wait for namespace to be fully gone before re-running
# oc wait --for=delete project/grafana --timeout=120s

# # 6. (Optional) Remove user workload monitoring config
# oc delete configmap cluster-monitoring-config -n openshift-monitoring --ignore-not-found