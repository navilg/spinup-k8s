#!/usr/bin/env bash

# MIT License

# Copyright (c) 2022 Navratan Gupta

# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:

# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

export KUBECONFIG=/home/$SUDO_USER/.kube/config

function exitWithMsg()
{
    # $1 is error code
    # $2 is error message
    echo "Error $1: $2"
    exit $1
}

function exitAfterCleanup()
{
    echo "Error $1: $2"
    clean $1
}

function clean()
{
    # $1 is error code
    echo
    echo "Cleaning up, before exiting..."
    if [[ "$(which k3d)" != "" ]]; then
        sleep 2
        k3d cluster delete $clusterName
    fi
    if [ -d /home/$SUDO_USER/.kube ]; then
        sudo chown -R $SUDO_USER:$SUDO_USER /home/$SUDO_USER/.kube
    fi
    exit $1
}

trap 'clean $?' ERR SIGINT

if [ $EUID -ne 0 ]; then
    exitWithMsg 1 "Run this as root or with sudo privilege."
fi

basedir=$(cd $(dirname $0) && pwd)

k3dVersion="v5.4.5"
k3sversion="v1.24.3-k3s1"
kubectlVersion="v1.24.4"
metallbVersion="v0.13.4"
ingressControllerVersion="v1.2.1"

k3dclusterinfo="/home/$SUDO_USER/k3dclusters.info"

totalMem=$(free --giga | grep -w Mem | tr -s " "  | cut -d " " -f 2)

usedMem=$(free --giga | grep -w Mem | tr -s " "  | cut -d " " -f 3)

availableMem=$(expr $totalMem - $usedMem)

echo "Available Memory: "$availableMem"Gi"

distroId=$(grep -w ID_LIKE /etc/os-release | cut -d "=" -f 2)
distroVersion=$(grep -w DISTRIB_RELEASE /etc/*-release | cut -d "=" -f 2)

echo "Distro: $distroId:$distroVersion"

if [ $availableMem -lt 2 ]; then
    exitWithMsg 1 "Atleast 2Gi of free memory required."
fi

if [ "$distroId" != "ubuntu" -a "$distroId" != "debian" ]; then
    exitWithMsg 1 "Unsupported Distro. This script is written for Debian-based OS only."
fi

if [ -d /home/$SUDO_USER/.kube ]; then
    sudo chown -R root:root /home/$SUDO_USER/.kube
fi

echo
read -p "Enter cluster name [ Default: linuxshots-RANDOMDIGITS ]: " clusterName
read -p "Enter number of worker nodes (0 to 3) (1Gi memory per node is required) [ Default: 0 ]: " nodeCount
read -p "Enter kubernetes api port (recommended: 5000-5500) [ Default: 5000 ]: " apiPort
echo

if [ -z $clusterName ]; then
    clusterName=linuxshots-$(head -n 100 /dev/urandom | tr -dc 0-9 | cut -c 1-6)
fi

if [ -z $apiPort ]; then
    apiPort=5000
fi

if [ -z $nodeCount ]; then
    nodeCount=0
fi

if [[ $apiPort != ?(-)+([0-9]) ]]; then
    exitWithMsg 1 "$apiPort is not a port. Port must be a number"
fi

if [[ $nodeCount != ?(-)+([0-9]) ]]; then
    exitWithMsg 1 "$nodeCount is not a number. Number of worker node must be a number"
fi

echo
echo "Updating apt packages."
sudo apt update
echo

echo "Checking docker..."
if [[ "$(which docker)" == "" ]]; then
    echo "Docker not found. Installing."
    sudo apt-get remove docker docker-engine docker.io containerd runc
    sudo apt install docker.io
    echo "Docker installed."
fi

echo "Checking K3d..."
if [[ "$(which k3d)" == "" ]]; then
    echo "K3d not found. Installing."
    curl -LO https://raw.githubusercontent.com/rancher/k3d/main/install.sh | TAG=$k3dVersion bash
    echo "K3d installed."
fi

sleep 2

echo
echo "Checking if cluster already exists."
hasCluster=$(k3d cluster list | grep -w $clusterName | cut -d " " -f 1)
if [ "$hasCluster" == "$clusterName" ]; then
    exitWithMsg 100 "Cluster with name $clusterName already exist."
fi

echo
echo "Creating cluster"
echo
k3d cluster create $clusterName --image rancher/k3s:$k3sversion --api-port $apiPort --agents $nodeCount --k3s-arg "--disable=traefik@server:0" --k3s-arg "--disable=servicelb@server:0" --no-lb --wait --timeout 15m
echo "Cluster $clusterName created."

echo "Checking kubectl..."
if [[ "$(which kubectl)" == "" ]]; then
    echo "kubectl not found. Installing."
    curl -LO https://dl.k8s.io/release/$kubectlVersion/bin/linux/amd64/kubectl
    chmod +x kubectl
    sudo mv ./kubectl /usr/local/bin/kubectl
    echo "Kubectl installed."
fi

sleep 2

kubectl cluster-info

if [ $? -ne 0 ]; then
    exitAfterCleanup 1 "Failed to spinup cluster."
fi

echo
echo "Deploying MetalLB loadbalancer."
echo
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/$metallbVersion/manifests/namespace.yaml
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/$metallbVersion/manifests/metallb.yaml
echo "Waiting for MetalLB to be ready. It may take 10 seconds or more."
sleep 10
kubectl wait --timeout=150s --for=condition=ready pod -l app=metallb,component=controller -n metallb-system
sleep 5

echo "Installing json parser."
sudo apt install jq -y
cidr_block=$(docker network inspect k3d-$clusterName | jq '.[0].IPAM.Config[0].Subnet' | tr -d '"')
base_addr=${cidr_block%???}
first_addr=$(echo $base_addr | awk -F'.' '{print $1,$2,$3,240}' OFS='.')
range=$first_addr/29

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: metallb-system
  name: config
data:
  config: |
    address-pools:
    - name: default
      protocol: layer2
      addresses:
      - $range
EOF

echo
echo "Deploying Nginx Ingress Controller."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-$ingressControllerVersion/deploy/static/provider/aws/deploy.yaml
echo "Waiting for Nginx Ingress controller to be ready. It may take 10 seconds or more."
sleep 5
kubectl wait --timeout=180s  --for=condition=ready pod -l app.kubernetes.io/component=controller,app.kubernetes.io/instance=ingress-nginx -n ingress-nginx

sleep 5

echo "Getting Loadbalancer IP"
externalIP=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "LoadBalancer IP: $externalIP"

echo
echo "Deploying a sample app."
kubectl apply -f https://raw.githubusercontent.com/navilg/spinup-k8s/master/sample-app.yaml
echo "Waiting for sample application to be ready. It may take 10 seconds or more."
sleep 5
kubectl wait --timeout=150s --for=condition=ready pod -l app=nginx -n sample-app

sleep 5
echo "Sample app is deployed."
sudo chown -R $SUDO_USER:$SUDO_USER /home/$SUDO_USER/.kube

function clusterInfo()
{
    echo
    echo
    echo "---------------------------------------------------------------------------"
    echo "---------------------------------------------------------------------------"
    echo "Cluster name: $clusterName"
    echo "K8s server: https://0.0.0.0:$apiPort"
    echo "Ingress Load Balancer: $externalIP"
    echo "Open sample app in browser: http://$externalIP/sampleapp"
    echo "To stop this cluster (If running), run: k3d cluster stop $clusterName"
    echo "To start this cluster (If stopped), run: k3d cluster start $clusterName"
    echo "To delete this cluster, run: k3d cluster delete $clusterName"
    echo "To list all clusters, run: k3d cluster list"
    echo "To switch to another cluster (In case of multiple clusters), run: kubectl config use-context k3d-<CLUSTERNAME>"
    echo "---------------------------------------------------------------------------"
    echo "---------------------------------------------------------------------------"
    echo
}
clusterInfo | tee -a "$k3dclusterinfo"
chown $SUDO_USER:$SUDO_USER "$k3dclusterinfo"
chmod 400 "$k3dclusterinfo"
echo "Find cluster info in "$k3dclusterinfo" file."
echo "|-- THANK YOU --|"
echo