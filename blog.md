# Creating a Tekton Pipeline for iter8

Recently released iter8 provides a means by which a new version of a service can be progressively rolled out using canary testing. Iter8 automatically configures Istio to gradually shift traffic from a current version to a new version. It compares metrics between the two versions and proceeds if the behavior of the new version is acceptable. Otherwise, it rolls back.

In this blog, we explore the inclusion of canary testing in a CI/CD pipeline implemented using Tekton. In the first part we explore how to define a build, deploy and test pipeline. In the second part of the blog we explore its integration into Github via webhooks to create a truly automated flow. We will use a sample application created to demonstrate features of Istio, bookinfo.

## Summary of iter8

Iter8 automatically configures Istio to gradually shift traffic from a current version of a Kubernetes application to a new version. It does this over time based on an assessment of the success of the new version. This assessment can be on its own or in comparison to the existing version. Iter8 is implemented by a Kubernetes controller that watches for instances of an `experiment.iter8.tools` resource and managing the state of Istio over time to implement the traffic shift defined by the `experiment`. An `experiment` specification comprises three main subsections:

- `targetService`: Identifies the deployments of the two versions of the service that will participate in the canary rollout.
- `trafficControl`: Identifies the stategy by which traffic will be shifted from one version to another.
- `analysis`: Defines the set of metrics that should be considered to determine if the new version is satisfactory and whether or not to continue.

For more details, see the [iter8 documentation]().

To manage traffic, iter8 defines (or modifies) an Istio `VirtualService` and `DestinationRule`. In this way, the percentage of traffic sent to each version can be changed.

Note that as a side effect of this approach, if the two versions of the application are running before any `VirtualService` is defined, traffic will, by default, be sent to both versions. To avoid this, the iter8 `experiment` should be created before deploying the candidate version. The iter8 controller will define the `VirtualService` that avoids this scenario.

## Pipline Overview

At a high level, the pipeline we wish to create contains the following three tasks:

    Build -> Create Experiment -> Deploy

Once the candidate version is deployed, the iter8 controller will manage the canary deployment.

Since we are using a toy application, we will need a way to drive load against the service. The iter8 analytics engine is not able to compare the candidate version to the existing base version if there is no load. We don't want to manually start this load, nor do we want to drive load when we aren't running a canary test. To do this, two additional tasks: one to generate load and one to monitor for completion that causes load to terminate. Finally, we can add a task to delete whichever version we decide not to keep.

Our pipeline now looks like this:

                               /-> Generate Load
    Build -> Create Experiment -> Deploy
                               \-> Wait For Completion -> Delete

## Task: Build New Version

We build our image and push it to DockerHub using [Kaniko](https://github.com/GoogleContainerTools/kaniko/).

We define the task as follows:

    apiVersion: tekton.dev/v1alpha1
    kind: Task
    metadata:
      name: build-task

To run the task, several additional resources are required.

First, we must define an image `PipelineResource` corresponding to the image that will be created. We plan to push the image to DockerHub so define the resource as follows:

    apiVersion: tekton.dev/v1alpha1
    kind: PipelineResource
    metadata:
      name: reviews-image
    spec:
      type: image
    params:
      - name: url
        value: index.docker.io/<your docker namespace>/reviewsx

Second, we need to define a secret that will be used to authenticate with DockerHub. This will be needed to push the image once it is built. We use basic authentication as follows:

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

Additional approches are possible. See [Tekton Authentication](https://github.com/tektoncd/pipeline/blob/master/docs/auth.md) for details.

Third, a service account with access to this secret should be defined that will be used to execute the builder:

    apiVersion: v1
    kind: ServiceAccount
    metadata:
      name: builder
    secrets:
      - name: dockerhub

## Task: Create Experiment

    apiVersion: tekton.dev/v1alpha1
    kind: Task
    metadata:
      name: create-experiment-task

## Task: Deploy New Version

To deploy an image, we use [kustomize]() to create a version specific deployment yaml. This allows us genertate as many resources as are needed; there is no assumption that only a `Deployment` is being created. We assume the kustomize configuration is stored in the source code repository.
The task implements 4 steps:

1. `modify-patch` - modifies a kustomize patch to be version aware
2. `kustomize` - generates the deployment yaml by applying the patch
3. `log-deployment` - logs the generated deployment yaml
4. `apply` - applies the deployment yaml via `kubectl`

The full task definition is:

    apiVersion: tekton.dev/v1alpha1
    kind: Task
    metadata:
      name: deploy-task

## Task: Generate Load

    apiVersion: tekton.dev/v1alpha1
    kind: Task
    metadata:
      name: generate-load-task

## Task: Wait for completion

A task to test for completion monitors 

    apiVersion: tekton.dev/v1alpha1
    kind: Task
    metadata:
      name: wait-completion-task

## Pipeline: Putting it together

## Running the Pipeline

    apiVersion: tekton.dev/v1alpha1
    kind: Pipeline
    metadata:
      name: build-canary-deploy-pipeline
