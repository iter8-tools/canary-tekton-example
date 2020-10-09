# Work In Progress

# Tekton Pipeline for Canary Rollout with iter8 on Red Hat OpenShift

## Prerequisite Steps

### Required Software

Replace **Istio** with **Red Hat OpenShift Service Mesh**.

Replace **Tekton** with **OpenShift Pipelines**.

### Authorize the Pipeline

The following additional permissions are required:

```bash
kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: oc-tekton-iter8-role
rules:
- apiGroups: [ "route.openshift.io" ]
  resources: [ "routes" ]
  verbs: [ "get", "list", "watch" ]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: oc-tekton-iter8-${PIPELINE_NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: oc-tekton-iter8-role
subjects:
- kind: ServiceAccount
  name: ${SERVICE_ACCOUNT}
  namespace: ${PIPELINE_NAMESPACE}
EOF
```

### Define Workspaces

## Define the Pipeline

Augment tasks:

```bash
kubectl --namespace ${PIPELINE_NAMESPACE} apply \
    --filename https://raw.githubusercontent.com/kalantar/iter8-tekton/master/openshift/task-overrides.yaml
```

## Running the Pipeline

```bash
export HOST=$(oc -n istio-system get route istio-ingressgateway -o jsonpath='{.spec.host}')

kubectl apply --filename - <<EOF
apiVersion: tekton.dev/v1beta1
kind: PipelineRun
metadata:
  name: canary-rollout
spec:
  pipelineRef:
    name: canary-rollout-iter8
  workspaces:
  - name: source
    persistentVolumeClaim:
      claimName: source-storage
  - name: experiment-dir
    persistentVolumeClaim:
      claimName: experiment-storage
  params:
  - name: application-source
    value: https://github.com/kalantar/reviews
  - name: application-namespace
    value: ${APPLICATION_NAMESPACE}
  - name: application-image
    value: kalantar/reviews
  - name: application-query
    value: productpage

  - name: HOST
    value: "${HOST}"

  - name: experiment-template
    value: iter8/experiment.yaml
EOF
```
