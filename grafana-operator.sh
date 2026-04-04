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
EOF

# 2. Create Grafana project
oc get project grafana &>/dev/null || { oc new-project grafana >/dev/null && echo "project.project.openshift.io/grafana created"; }

# 3. Create service account
oc apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: grafana-sa
  namespace: grafana
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

# 5. Create long-lived SA token secret for Prometheus authentication
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

# 6. Sync prometheus-credentials secret with the current SA token
TOKEN=$(oc -n grafana get secret grafana-sa-token --template='{{ .data.token | base64decode }}')
oc create secret generic prometheus-credentials \
  --from-literal=PROMETHEUS_TOKEN="Bearer $TOKEN" \
  -n grafana \
  --dry-run=client -o yaml | oc apply --server-side -f -

# 7. Add Grafana Helm repo and install Grafana Operator
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

# 8. Print the Grafana route
ROUTE=$(oc -n grafana get route grafana-route -o jsonpath='{.spec.host}')
echo -e "\nGrafana is available at: http://$ROUTE\n"

echo "Day 0 bootstrap complete."