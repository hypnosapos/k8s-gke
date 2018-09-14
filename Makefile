.DEFAULT_GOAL := help

# Shell to use with Make
SHELL ?= /bin/bash
ROOT_PATH := $(PWD)/$({0%/*})

GCLOUD_IMAGE_TAG    ?= alpine
GCP_CREDENTIALS     ?= $$HOME/gcp.json
GCP_ZONE            ?= my_zone
GCP_PROJECT_ID      ?= my_project

GKE_CLUSTER_VERSION ?= 1.10.7-gke.1
GKE_CLUSTER_NAME    ?= my_cluster
GKE_NODES_MIN       ?= 1
GKE_NODES           ?= 2
GKE_NODES_MAX       ?= 3
GKE_IMAGE_TYPE      ?= n1-standard-8

GKE_GPU_AMOUNT      ?= 1
GKE_GPU_TYPE        ?= nvidia-tesla-v100

GKE_POOL_NAME       ?= nodes

## Needed for more efficient github downloading proccesses
GITHUB_TOKEN        ?= githubtoken

UNAME := $(shell uname -s)
ifeq ($(UNAME),Linux)
OPEN := xdg-open
else
OPEN := open
endif

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

.PHONY: clean-all
clean-all: gke-destroy-cluster clean-docker## remove all build, test, coverage and Python artifacts


.PHONY: clean-docker
clean-docker: ## Remove docker containers and their images
	@docker rm -f gke-bastion > /dev/null 2>&1 || true

.PHONY: gke-bastion
gke-bastion: ## Run a gke-bastion container with port 8001 for proxy.
	@docker run -it -d --name gke-bastion \
	   -p 8001:8001 \
	   -v $(GCP_CREDENTIALS):/tmp/gcp.json \
	   -v $(ROOT_PATH):/cartpole-rl-remote \
	   google/cloud-sdk:$(GCLOUD_IMAGE_TAG) \
	   sh
	@docker exec gke-bastion \
	   sh -c "gcloud components install kubectl beta --quiet \
	          && gcloud auth activate-service-account --key-file=/tmp/gcp.json"

.PHONY: gke-create-cluster
gke-create-cluster: ## Create a kubernetes cluster on GKE.
	@docker exec gke-bastion \
	   sh -c "gcloud beta container --project $(GCP_PROJECT_ID) clusters create $(GKE_CLUSTER_NAME) --zone "$(GCP_ZONE)" \
	          --username "admin" --cluster-version "$(GKE_CLUSTER_VERSION)" --machine-type "$(GKE_IMAGE_TYPE)" \
	          --image-type "COS" --disk-type "pd-standard" --disk-size "100" \
	          --scopes "compute-rw","storage-rw","logging-write","monitoring","service-control","service-management","trace" \
	          --num-nodes "$(GKE_NODES)" --min-nodes $(GKE_NODES_MIN) --max-nodes $(GKE_NODES_MAX) \
	          --enable-cloud-logging --enable-cloud-monitoring --network "default" \
	          --subnetwork "default" --addons HorizontalPodAutoscaling,HttpLoadBalancing,KubernetesDashboard"
	@docker exec gke-bastion \
	   sh -c "gcloud container clusters get-credentials $(GKE_CLUSTER_NAME) --zone "$(GCP_ZONE)" --project $(GCP_PROJECT_ID) \
	          && kubectl config set-credentials gke_$(GCP_PROJECT_ID)_$(GCP_ZONE)_$(GKE_CLUSTER_NAME) --username=admin \
	          --password=$$(gcloud container clusters describe --zone "$(GCP_ZONE)" $(GKE_CLUSTER_NAME) | grep password | awk '{print $$2}')"

.PHONY: gke-ui-login-skip
gke-ui-login-skip: ## TRICK: Grant complete access to dashboard. Be careful, anyone could enter into your dashboard and execute unexpected ops.
	@docker cp $(ROOT_PATH)skip_login.yml gke-bastion:/tmp/skip_login.yml
	@docker exec gke-bastion \
	  sh -c "kubectl create -f /tmp/skip_login.yml"

.PHONY: gke-proxy
gke-proxy: ## Run kubectl proxy on gke container.
	@docker exec -it -d gke-bastion \
	   sh -c "kubectl proxy --address='0.0.0.0'"

.PHONY: gke-tiller-helm
gke-tiller-helm: ## Install tiller and helm.
	@docker exec gke-bastion \
	  sh -c "apk --update add openssl \
	         && curl  -H 'Cache-Control: no-cache' -H 'Authorization: token $(GITHUB_TOKEN)' https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get | bash \
	         && kubectl -n kube-system create sa tiller \
	         && kubectl create clusterrolebinding tiller --clusterrole cluster-admin --serviceaccount=kube-system:tiller \
	         && helm init --wait --service-account tiller"

.PHONY: gke-create-gpu-nvidia-driver
gke-create-gpu-nvidia-driver:
	@docker exec gke-bastion \
	  sh -c "kubectl apply -f \
	    https://raw.githubusercontent.com/GoogleCloudPlatform/container-engine-accelerators/stable/nvidia-driver-installer/cos/daemonset-preloaded.yaml"

.PHONY: gke-create-pool
gke-create-pool: ## Create a node pool.
	@docker exec gke-bastion \
	  sh -c "gcloud config set project $(GCP_PROJECT_ID) && gcloud container node-pools create $(GKE_POOL_NAME) \
	         --zone $(GCP_ZONE) \
	         --cluster $(GKE_CLUSTER_NAME) --num-nodes $(GKE_NODES) --min-nodes $(GKE_NODES_MIN) \
	         --max-nodes $(GKE_NODES_MAX) --machine-type "$(GKE_IMAGE_TYPE)" --enable-autoscaling --preemptible"

.PHONY: gke-create-gpu-pool
gke-create-gpu-pool: ## Create a GPU node pool.
	@docker exec gke-bastion \
	  sh -c "gcloud config set project $(GCP_PROJECT_ID) && gcloud container node-pools create $(GKE_POOL_NAME)-gpu \
	         --accelerator type=$(GKE_GPU_TYPE),count=$(GKE_GPU_AMOUNT) --zone $(GCP_ZONE) \
	         --cluster $(GKE_CLUSTER_NAME) --num-nodes $(GKE_NODES) --min-nodes $(GKE_NODES_MIN) \
	         --max-nodes $(GKE_NODES_MAX) --machine-type "$(GKE_IMAGE_TYPE)" --enable-autoscaling --preemptible"

.PHONY: gke-destroy-pool
gke-destroy-pool: ## Destroy a node pool.
	@docker exec gke-bastion \
	  sh -c "gcloud config set project $(GCP_PROJECT_ID) && gcloud container node-pools delete $(GKE_POOL_NAME) \
	         --zone $(GCP_ZONE) --cluster $(GKE_CLUSTER_NAME)"


.PHONY: gke-destroy-cluster
gke-destroy-cluster: ## Destroy the cluster.
	@docker exec gke-bastion \
	   sh -c "gcloud config set project $(GCP_PROJECT_ID) && gcloud config set project $(GCP_PROJECT_ID) \
	          && gcloud container --project $(GCP_PROJECT_ID) clusters delete $(GKE_CLUSTER_NAME) \
	          --zone $(GCP_ZONE) --quiet"

.PHONY: gke-ui
gke-ui: ## Launch kubernetes dashboard through the proxy.
	$(OPEN) http://localhost:8001/api/v1/namespaces/kube-system/services/https:kubernetes-dashboard:/proxy/