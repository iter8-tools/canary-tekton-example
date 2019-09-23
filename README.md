# Creating a Tekton Pipeline Using iter8 to Rollout Applications

Recently released iter8 provides a means by which a new version of a service can be progressively rolled out using canary testing. Iter8 automatically configures Istio to gradually shift traffic from a current version to a new version. It compares metrics between the two versions and proceeds if the behavior of the new version is acceptable. Otherwise, it rolls back.

In this blog, we explore the inclusion of canary testing in a CI/CD pipeline implemented using Tekton. In the first part we explore how to define a build, deploy and test pipeline. In the second part of the blog we explore its integration into Github via webhooks to create a truly automated flow. We will use a sample application created to demonstrate features of Istio, bookinfo.

## Overview of iter8

Iter8 automatically configures Istio to gradually shift traffic from a current version of a Kubernetes application to a new version. It does this over time based on an assessment of the success of the new version. This assessment can be on its own or in comparison to the existing version. Iter8 is implemented by a Kubernetes controller that watches for instances of an `experiment.iter8.tools` resource and managing the state of Istio over time to implement the traffic shift defined by the `experiment`. An `experiment` specification comprises three main subsections:

- `targetService`: Identifies the deployments of the two versions of the service that will participate in the canary rollout.
- `trafficControl`: Identifies the stategy by which traffic will be shifted from one version to another.
- `analysis`: Defines the set of metrics that should be considered to determine if the new version is satisfactory and whether or not to continue.

For more details, see the [iter8 documentation]().

To manage traffic, iter8 defines (or modifies) an Istio `VirtualService` and `DestinationRule`. In this way, the percentage of traffic sent to each version can be changed.

Note that as a side effect of this approach, if the two versions of the application are running before any `VirtualService` is defined, traffic will, by default, be sent to both versions. To avoid this, the iter8 `experiment` should be created before deploying the candidate version. The iter8 controller will define the `VirtualService` that avoids this scenario.

## Overview of Tekton

## Pipline Overview

At a high level, the pipeline we wish to create contains the following three tasks:

    Build -> Create Experiment -> Deploy

Once the candidate version is deployed, the iter8 controller will manage the canary deployment.

Since we are using a toy application, we will need a way to drive load against the service. The iter8 analytics engine is not able to compare the candidate version to the existing base version if there is no load. We don't want to manually start this load, nor do we want to drive load when we aren't running a canary test. To do this, two additional tasks: one to generate load and one to monitor for completion that causes load to terminate. Finally, we can add a task to delete whichever version we decide not to keep.

Our pipeline now looks like this:

                               /-> Generate Load
    Build -> Create Experiment -> Deploy
                               \-> Wait For Completion -> Delete

Each task is reviewed in detail in the subsequence sections below.

For your convenience, the definitions used in this blog can be found in [here](http://github.com/iter8-tools/iter8-tekton-blog).

## Preparation

### Sample Application

We will explore a pipline for the reivews microservice in the [bookinfo application](https://istio.io/docs/examples/bookinfo/), a sample application developed for demonstrating features of Istio. In particiular, we will build a pipeline for building and rolling out new versions of the reviews microservice. For simplicity the source this service has been copied to [this repository](https://github.com/iter8-tools/bookinfoapp-reviews) which can be cloned for your own testing.

Since the microservice is one of serveral that comprise the application, it is necessary to deploy the remaining services to your cluster. The following code can be used to do so (it assumes target namespace `bookinfo`)

    kubectl create namespace bookinfo
    kubectl label namespace istio-injection=enabled
    kubectl --namespace bookinfo apply --filename https://raw.githubusercontent.com/iter8-tools/iter8-toolchain-rollout/master/scripts/bookinfo.yaml
    curl -s https://raw.githubusercontent.com/iter8-tools/iter8-toolchain-rollout/master/scripts/bookinfo-gateway.yaml \
      | sed 's/sample.dev/bookinfo/' \
      | apply --namespace bookinfo --filename -

You can test the application:

    curl 

### Define PipelineResources

In order to load a GitHub project and write/read a DockerHub image, in a Tekton pipeline, it is necessary to define `PipelineResource` resources. For additional details about `PipelineResource`, see the [Tekton documentation](https://github.com/tektoncd/pipeline/blob/master/docs/resources.md). 
Two resources are needed, one for the git project and for the DockerHub image we will build.

You can create the GitHub repo by cloning the [iter8 repo](https://github.com/iter8-tools/bookinfoapp-reviews) The Github resource can be specified as:

apiVersion: tekton.dev/v1alpha1
kind: PipelineResource
metadata:
  name: reviews-repo
spec:
  type: git
  params:
  - name: revision
    value: master
  - name: url
    value: https://github.com/<your github org>/bookinfoapp-reviews

The DockerHub image can be specified as:
    apiVersion: tekton.dev/v1alpha1
    kind: PipelineResource
    metadata:
      name: reviews-image
    spec:
      type: image
    params:
      - name: url
        value: index.docker.io/<your docker namespace>/reviews

### Authentication

We need to define a secret that will be used to authenticate with DockerHub. This will be needed to push the image once it is built. We use basic authentication as follows:

    apiVersion: v1
    kind: Secret
    metadata:
      name: dockerhub
      annotations:
        tekton.dev/docker-0: https://index.docker.io
    type: kubernetes.io/basic-auth
    stringData:
      username: <your DockerHub username>
      password: <your DockerHub password>

If your git repository is private you will also need to define a secret to allow Tekton to access it. In our case, we use a public repository.

For additional information on authentication, see the [Tekton Documentation](https://github.com/tektoncd/pipeline/blob/master/docs/auth.md).

### Add Secret (s) to ServiceAccount

You can use any `ServiceAccount`. If you use a non-default account, it will be necessary to specify this in the `PipelineRun` you create to run the pipeline (see below). For simplicity, we used the default service account.

## Task: Build New Version

We build our image and push it to DockerHub using [Kaniko](https://github.com/GoogleContainerTools/kaniko/).
Kaniko both builds and pushes the resulting image to DockerHub. The full Tekton `Task` definition is [here](https://github.ibm.com/kalantar/iter8-tekton-blog/blob/master/tasks/build.yaml).

## Task: Create Experiment

Iter8 configures Istio to gradually shift traffic from a current version of a Kubernetes application to a new version. It does this over time based on an assessment of the success of the new version. This assessment can be on its own or in comparison to the existing version. The `Experiment` that specifies this rollout is created from a template stored in `<repo>/iter8/experiment.yaml`. The `Create Experiemnt` task modifies this template to identify the current and next versions and creates the `Experiment`.

The main challenge is to identify the current version. We rely on labels iter8 adds to the `DestinationRule`. These are used to match against the `Deployment` objects to find the current version. If iter8 has never been used, these labels do not exist so we select randomly select one of the matching deployments.

For the new version we use the short commit id of the repo being built.

The full definition of the Tekton `Task` is [here](https://github.ibm.com/kalantar/iter8-tekton-blog/blob/master/tasks/create-experiment.yaml).

## Task: Deploy New Version

To deploy an image, we use [kustomize](https://github.com/kubernetes-sigs/kustomize) to create a version specific deployment yaml. This allows us genertate as many resources as are needed; there is no assumption that only a `Deployment` is being created. We assume the kustomize configuration is stored in the source code repository.
The task implements 4 steps:

1. `modify-patch` - modifies a kustomize patch to be version aware
2. `kustomize` - generates the deployment yaml by applying the patch
3. `log-deployment` - logs the generated deployment yaml
4. `apply` - applies the deployment yaml via `kubectl`

The full Tekton `Task` definition is [here](https://github.ibm.com/kalantar/iter8-tekton-blog/blob/master/tasks/deploy.yaml).

## Task: Generate Load

Iter8 can evaluate the success of a new version if there is load against the system. The load generates meaninful metric data used by iter8 to assess the new version. Since bookinfo is a toy application, we added a task to our pipeline to generate load against the application. The benefit of adding a task instead of doing this manually is that we don't forget to start the load generation.

Once we start load, we face the problem of stopping it when a canary rollout is complete. To accomplish this we add a shared persistent volume between this task and the "wait-completion" task. When the latter identifies a completed rollout, it touches a file on the shared volume. The load-generator watches for this change and terminates the load.

For simplicity we used a volume of type HostPath. This works because we are using a single node cluster:

    kind: PersistentVolume
    apiVersion: v1
    metadata:
      name: experiment-stop-volume
    spec:
      storageClassName: manual
      capacity:
        storage: 100Ki
      accessModes:
        - ReadWriteOnce
      hostPath:
        path: "/mnt/stop"
    ---
    kind: PersistentVolumeClaim
    apiVersion: v1
    metadata:
      name: experiment-stop-claim
    spec:
      storageClassName: manual
      accessModes:
        - ReadWriteOnce
      resources:
        requests:
          storage: 2Ki

The final Tekton `Task` definition is [here](https://github.ibm.com/kalantar/iter8-tekton-blog/blob/master/tasks/generate-load.yaml)

## Task: Wait for completion

A task to test for completion monitors progress. When the canary rollout is complete, it identifies (based on the `status` of the `Experiment`) which deployment (the original or the the new) is being used and deletes the other one to save resources. Finally, it touches a shared file to trigger the termination of load.

The Tekton `Task` definition is [here](https://github.ibm.com/kalantar/iter8-tekton-blog/blob/master/tasks/wait-completion.yaml)

## Putting it together

    apiVersion: tekton.dev/v1alpha1
    kind: Pipeline
    metadata:
      name: build-canary-deploy-pipeline

## Running the Pipeline

## Conclusions
