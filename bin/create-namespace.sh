set -x

GITREVISION=master

while (( $# > 0 )); do
  case "${1}" in
    --namespace|-n) 
      NAMESPACE="${2}"
      shift
      shift
      ;;
    --url)
      GITREPOSITORYURL="${2}"
      shift
      shift
      ;;
    --revision|-r)
      GITREVISION="${2}"
      shift
      shift
      ;;
    *)
      shift
      ;;
  esac
done

if [[ -z "${NAMESPACE}" ]]; then
  echo "ERROR: namespace required"
  echo "Usage: $0 --namespace NAMESPACE --url GITREPOSITORYURL"
  exit 1
fi
if [[ -z "${GITREPOSITORYURL}" ]]; then
  echo "ERROR: git repository required"
  echo "Usage: $0 --namespace NAMESPACE --url GITREPOSITORYURL"
  exit 1
fi

kubectl --namespace default apply --filename - <<EOF
apiVersion: tekton.dev/v1alpha1
kind: PipelineRun
metadata:
  name: setup-namespace-${NAMESPACE}
spec:
  pipelineSpec:
    resources:
      - name: git-source
        type: git
    params:
      - name: target-namespace
        type: string
        default: default

      - name: serviceaccount
        type: string
        default: default
      - name: docker-secret
        type: string
        default: dockerhub

      - name: pathToDockerFile
        type: string
        default: /workspace/git-source/Dockerfile
      - name: pathToContext
        type: string
        default: /workspace/git-source
    tasks:
      - name: create-namespace
        taskRef:
          name: create-namespace-task
        params:
          - name: namespace
            value: ${NAMESPACE}
      - name: deploy-app
        taskRef:
          name: deploy-bookinfo-task
        runAfter:
          - create-namespace
        resources:
          inputs:
            - name: git-source
              resource: git-source
        params:
          - name: target-namespace
            value: ${NAMESPACE}
      - name: create-volume
        taskRef:
          name: create-volume-task
        runAfter: [ "create-namespace" ]
        params:
          - name: target-namespace
            value: "$(params.namespace1)"
      - name: setup-tasks
        runAfter:
          - create-namespace
        taskSpec:
          steps:
            - name: add-build-task
              image: lachlanevenson/k8s-kubectl
              command: [ "kubectl" ]
              args:
                - --namespace
                - ${NAMESPACE}
                - apply
                - --filename
                - https://raw.githubusercontent.com/kalantar/iter8-tekton/master/tasks/build.yaml
                - --filename
                - https://raw.githubusercontent.com/kalantar/iter8-tekton/master/tasks/create-experiment.yaml
                - --filename
                - https://raw.githubusercontent.com/kalantar/iter8-tekton/master/tasks/generate-load.yaml
                - --filename
                - https://raw.githubusercontent.com/kalantar/iter8-tekton/master/tasks/deploy.yaml
                - --filename
                - https://raw.githubusercontent.com/kalantar/iter8-tekton/master/tasks/wait-completion.yaml
                - --filename
                - https://raw.githubusercontent.com/kalantar/iter8-tekton/master/tasks/deployrun.yaml
  resources:
    - name: git-source
      resourceSpec:
        type: git
        params:
          - name: url
            value: ${GITREPOSITORYURL}
          - name: revision
            value: ${GITREVISION}
  params:
      - name: target-namespace
        value: ${NAMESPACE}
EOF
