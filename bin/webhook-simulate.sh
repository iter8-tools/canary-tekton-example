#!/bin/bash

DRYRUN=
DEBUG=
while [ $# -gt 0 ]; do
  case "${1}" in
    --dry-run) 
        DRYRUN=TRUE
        DEBUG=TRUE
        shift
        ;;
    -v) DEBUG=TRUE
        shift
        ;;
    *) break
  esac
done

WEBHOOK_ID="${1}"

#PROJECT='https://github.com/kalantar/reviews'
PROJECT=$(git remote get-url --push origin | sed 's/git@\(.*\):/https:\/\/\1\//' | sed 's/.git$//')
PROJECT_SHORTNAME=$(basename ${PROJECT})

SHORT_COMMITID=$(git rev-parse --short HEAD) 

REGISTRY="index.docker.io/kalantar"
REPOSITORY_NAME=${PROJECT_SHORTNAME}

PIPELINERUN_NAMESPACE="bookinfo-iter8"

if [[ -n ${DEBUG} ]]; then
echo "           WEBHOOK_ID = $WEBHOOK_ID"
echo "              PROJECT = $PROJECT"
echo "    PROJECT_SHORTNAME = $PROJECT_SHORTNAME"
echo "       SHORT_COMMITID = $SHORT_COMMITID"
echo "             REGISTRY = $REGISTRY"
echo "      REPOSITORY_NAME = $REPOSITORY_NAME"
echo "PIPELINERUN_NAMESPACE = $PIPELINERUN_NAMESPACE"
fi

TMP="/tmp/whs.$$"
# Create PipelineResource of type git
cat << EOF >> $TMP
apiVersion: tekton.dev/v1alpha1
kind: PipelineResource
metadata:
  name: ${REPOSITORY_NAME}-repo-${WEBHOOK_ID}
spec:
  type: git
  params:
  - name: revision
    value: ${SHORT_COMMITID}
  - name: url
    value: ${PROJECT}
EOF
echo "---" >> $TMP

# Create PipelineResource of type image
cat << EOF >> $TMP
apiVersion: tekton.dev/v1alpha1
kind: PipelineResource
metadata:
  name: ${REPOSITORY_NAME}-docker-image-${WEBHOOK_ID}
spec:
  type: image
  params:
  - name: url
    value: ${REGISTRY}/${REPOSITORY_NAME}:${SHORT_COMMITID}
EOF
echo "---" >> $TMP

# Create PipelineRun
cat << EOF >> $TMP
apiVersion: tekton.dev/v1alpha1
kind: PipelineRun
metadata:
  name: ${PROJECT_SHORTNAME}-${WEBHOOK_ID}
spec:
  pipelineRef:
    name: build-canary-deploy-iter8-pipeline
  resources:
    - name: git-source
      resourceRef:
        name: ${REPOSITORY_NAME}-repo-${WEBHOOK_ID}
    - name: docker-image
      resourceRef:
        name: ${REPOSITORY_NAME}-docker-image-${WEBHOOK_ID}
  params:
    - name: image-tag
      value: ${SHORT_COMMITID}
    - name: image-name
      value: ${REGISTRY}/${REPOSITORY_NAME}
    - name: release-name
      value: ${REPOSITORY_NAME}
    - name: repository-name
      value: ${REPOSITORY_NAME}
    - name: target-namespace
      value: ${PIPELINERUN_NAMESPACE}
    - name: docker-registry
      value: ${REGISTRY}
EOF
if [[ -n $DEBUG ]]; then cat $TMP; fi
if [[ -z $DRYRUN ]]; then kubectl apply -f $TMP; fi
rm $TMP 
