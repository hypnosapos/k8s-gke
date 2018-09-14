# k8s-gke
![We love open source](https://badges.frapsoft.com/os/v1/open-source.svg?v=103 "We love open source")

This project is intended to deploy a kubernetes cluster on GKE through a 
local docker container.

This is the schema of this simple deployer:

![k8s on GKE](schema.png)

## Requirements

- Make (gcc)
- Docker (17+)
- GCP project and the json file with credentials and GKE service enabled for your account.

## HOWTO

### Setup 

You have to provide some variables to connect with GKE service correctly.

You may use env variables, provide them via shell, modify variables directly on Makefile or load variables from other source, for instance we'll use a sh file `k8s-gke`.

### Create a cluster

Just type:

```bash
source k8s-gke.sh
make gke-bastion gke-create-cluster gke-ui-login-skip gke-proxy gke-ui 
```

When command above ends a web browser should be opened with the kubernetes dashboard.

If you want to use helm then tiller installation on kubernetes cluster is required:
```bash
make gke-tiller-helm
```

Now you can use the container gke-bastion as proxy for any gcloud or kubectl command, for instance:

```bash
docker exec -it gke-bastion bash -c 'gcloud compute accelerator-types list'
docker exec -it gke-bastion bash -c 'kubectl cluster-info'
docker exec -it gke-bastion bash -c 'helm install --name nginx-proba stable/nginx-ingress'
```

### Add node pool

```bash
GKE_NODE=3 GKE_NODE_MAX=10 GKE_IMAGE_TYPE=n1-standard-4 GKE_POOL_NAME=poor make gke-create-pool 
```


### Add gpu node pool

```bash
GKE_GPU_AMOUNT=2 GKE_GPU_TYPE=nvidia-tesla-v100 make gke-create-gpu-pool 
```

After pool of gpu is available you'll need to add drivers to nodes in order to kubernetes scheduler will be capable to allocate those resources: 

```bash
make gke-create-gpu-nvidia-driver
```
### Destroy a node pool

```bash
GKE_POOL_NAME=poor make gke-destroy-pool
```
### Clean all

```bash
make clean-all
```
