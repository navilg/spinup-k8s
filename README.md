# spinup-k8s
Spin-up a lightweight Kubernetes cluster on Ubuntu standalone VM with K3s, MetalLB and Nginx Ingress to setup learning or test environment.

## Spin up a test Kubernetes cluster 

```
curl -L https://raw.githubusercontent.com/navilg/spinup-k8s/master/spinup.sh -o spinup.sh
sudo bash spinup.sh
```

- Enter cluster name once prompted.

- Enter number of worker (Agent) node required. Minimum 1 recommended. 1Gi + 1Gi per worker node free memory is recommended.

- Enter kubernetes API port on which K8s will listen. Must be an unused port.
