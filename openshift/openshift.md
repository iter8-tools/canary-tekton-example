# Tekton Pipeline for Canary Rollout with iter8 on Red Hat OpenShift

These instructions are meant to be used in concert with those in the [README.md](../README.md). The instructions here are **additional** steps that must be taken to function on Openshift.

This was tested on RedHat Openshift 4.4.

## Prerequisite Steps

### Required Software

Replace **Istio** with **Red Hat OpenShift Service Mesh**. Install from the OperatorHub.

Replace **Tekton** with **OpenShift Pipelines**. Install from the OperatorHub.

### Authorize the Pipeline

The following additional permissions are required. They will provide the permissions to run the pipeline and to trigger it from a github push event.

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
- apiGroups: [ "" ]
  resources: [ "configmaps" ]
  verbs: [ "get", "list", "watch", "create", "update", "patch", "delete" ]
- apiGroups: [ "triggers.tekton.dev" ]
  resources: [ "eventlisteners", "triggerbindings", "triggertemplates" ]
  verbs: [ "get", "list", "watch", "create", "update", "patch", "delete" ]
- apiGroups: [ "tekton.dev" ]
  resources: [ "pipelineruns" ]
  verbs: [ "get", "list", "watch", "create", "update", "patch", "delete" ]
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

```bash
oc --namespace ${PIPELINE_NAMESPACE} apply \
    --filename https://raw.githubusercontent.com/kalantar/iter8-tekton/master/tasks.yaml \
    --filename https://raw.githubusercontent.com/kalantar/iter8-tekton/master/openshift/task-overrides.yaml \
    --filename https://raw.githubusercontent.com/kalantar/iter8-tekton/master/openshift/canary-pipeline.yaml
```

## Running the Pipeline

### Manual Execution

The pipeline can be run manually by creating a `PipelineRun` similar to this:

```bash
export HOST=$(oc -n istio-system get route istio-ingressgateway -o jsonpath='{.spec.host}')

oc apply --namespace ${PIPELINE_NAMESPACE} --filename - <<EOF
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
    value: ${GITHUB_REPO}
  - name: application-namespace
    value: ${APPLICATION_NAMESPACE}
  - name: application-image
    value: ${DOCKER_REPO}
  - name: application-query
    value: productpage

  - name: HOST
    value: "${HOST}"

  - name: experiment-template
    value: iter8/experiment.yaml
EOF
```

### Triggered by GitHub Push Events

#### Add Trigger Definition

Triggers enable a pipeline to respond to external events such as push events on a GitHub repository. To enable a trigger, it is necessary to define a `TriggerBinding` (which extracts values from a webhook payload), a `TriggerTemplate` (which defines a set of parameterrized objects to created) and an `EventListener` which maps the values extracted from the binding to template parameters and creates the objects.

We define a binding that extracts values from the webhook issued by a push event on a GitHub repository and a template that creates a `PipelineRun` to execute the pipeline.

```bash
oc --namespace ${PIPELINE_NAMESPACE} apply \
    --filename https://raw.githubusercontent.com/kalantar/iter8-tekton/master/openshift/trigger/binding.yaml
```

Define the template:

```bash
oc apply --namespace ${PIPELINE_NAMESPACE} --filename - <<EOF
apiVersion: triggers.tekton.dev/v1alpha1
kind: TriggerTemplate
metadata:
  name: reviews-template
spec:
  params:
  - name: git-repo-url
    description: The git repository url
  - name: git-revision
    description: The git revision
    default: master
  - name: git-repo-name
    description: The name of the deployment to be created / patched

  resourcetemplates:
  - apiVersion: tekton.dev/v1beta1
    kind: PipelineRun
    metadata:
      name: canary-rollout-$(params.git-repo-name)-$(uid)
    spec:
      pipelineRef:
        name: canary-rollout-iter8
      serviceAccountName: default
      workspaces:
      - name: source
        persistentVolumeClaim:
          claimName: source-storage
      - name: experiment-dir
        persistentVolumeClaim:
          claimName: experiment-storage
      params:
      - name: application-source
        value: ${GITHUB_REPO}
      - name: application-namespace
        value: bookinfo-pipeline
      - name: application-image
        value: ${DOCKER_REPO}
      - name: application-query
        value: productpage
      - name: HOST
        value: ${HOST}
      - name: experiment-template
        value: iter8/experiment.yaml
EOF
```

Finally, create the event listener:

```bash
oc --namespace ${PIPELINE_NAMESPACE} apply \
    https://raw.githubusercontent.com/kalantar/iter8-tekton/master/openshift/trigger/listener.yaml
```

#### Expose the Event Listener

The event listener must be exposed to external traffic:

```bash
oc --namespace ${PIPELINE_NAMESPACE} expose service el-reviews
```

#### Define a webhook in GitHub

Log in to GitHub and navigate to: `${GITHUB_REPO}/settings/hooks`. Create a new webhook setting:

- *Payload URL* to `$(oc  get route el-review --template='http://{{.spec.host}}')`
- *Content type* to `application/json`
- Set a secret (can be anything)
- Select just push events as triggers
- Check that the webhook is `Active`

Then select `Add webhook` to create the webhook.

#### Test the webhook

Make a change and commit the change to the master branch. The pipeline should be triggered and execute.

## References

[Pipelines](https://docs.openshift.com/container-platform/4.5/pipelines/creating-applications-with-cicd-pipelines.html).

More details on using [Triggers](https://docs.openshift.com/container-platform/4.5/pipelines/creating-applications-with-cicd-pipelines.html#adding-triggers_creating-applications-with-cicd-pipelines).