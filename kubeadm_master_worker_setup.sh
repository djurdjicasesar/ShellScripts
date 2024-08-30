#!/bin/bash

apt-get update
apt install unzip
apt install jq -y
sed -i "s/#\$nrconf{kernelhints} = -1;/\$nrconf{kernelhints} = -1;/g" /etc/needrestart/needrestart.conf
sed -i 's/#$nrconf{restart} = '"'"'i'"'"';/$nrconf{restart} = '"'"'a'"'"';/g' /etc/needrestart/needrestart.conf
DEBIAN_FRONTEND=noninteractive apt -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade -y

# aws cli

curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
./aws/install

IP=$(curl http://169.254.169.254/latest/meta-data/local-ipv4)

sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
swapoff -a

# configure ipv4 forwarding
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# sysctl params required by setup, params persist across reboots
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

# Apply sysctl params without reboot
sysctl --system

# Install containerd
wget https://github.com/containerd/containerd/releases/download/v1.7.3/containerd-1.7.3-linux-amd64.tar.gz
tar Czxvf /usr/local containerd-1.7.3-linux-amd64.tar.gz
wget https://raw.githubusercontent.com/containerd/containerd/main/containerd.service
mkdir -p /etc/containerd/
containerd config default | tee /etc/containerd/config.toml
sed -i 's/SystemdCgroup \= false/SystemdCgroup \= true/g' /etc/containerd/config.toml

# Install runc
wget https://github.com/opencontainers/runc/releases/download/v1.1.8/runc.amd64
install -m 755 runc.amd64 /usr/local/sbin/runc

# Containerd configuration for Kubernetes
mv containerd.service /etc/systemd/system/containerd.service
systemctl daemon-reload
systemctl enable containerd
systemctl start containerd

# Install cni-plugins
wget https://github.com/containernetworking/plugins/releases/download/v1.3.0/cni-plugins-linux-amd64-v1.3.0.tgz
mkdir -p /opt/cni/bin
tar Cxzvf /opt/cni/bin cni-plugins-linux-amd64-v1.3.0.tgz

# Install crictl
wget https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.27.1/crictl-v1.27.1-linux-amd64.tar.gz
tar -xvf crictl-v1.27.1-linux-amd64.tar.gz
mv crictl /usr/bin/crictl
cat <<EOF | tee /etc/crictl.yaml
runtime-endpoint: unix:///var/run/containerd/containerd.sock
image-endpoint: unix:///var/run/containerd/containerd.sock
timeout: 2
debug: true
pull-image-on-create: false
EOF

# Install kubeadm, kubelet and kubectl
curl -LO https://dl.k8s.io/release/v1.27.4/bin/linux/amd64/kubectl
curl -LO "https://dl.k8s.io/release/v1.27.4/bin/linux/amd64/kubectl.sha256"
install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
kubectl version -o yaml
apt-get update
apt-get install -y apt-transport-https ca-certificates curl
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list
apt-get update
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable kubelet
systemctl start kubelet

# git
apt-get install -y git-all

INSTANCE_ID=$(curl http://169.254.169.254/latest/meta-data/instance-id)
IP_ADDRESS=$(curl http://169.254.169.254/latest/meta-data/local-ipv4)
AWS_REGION=eu-central-1
CLUSTERNAME=$(aws ec2 describe-instances --instance-id ${INSTANCE_ID} --query "Reservations[0].Instances[0].Tags[?Key=='ClusterName'].Value" --output text --region ${AWS_REGION})
JOIN_SECRET="/${CLUSTERNAME}/kubernetes/JoinSecret"
PROVIDER_ID="aws:///${AWS_REGION}/${INSTANCE_ID}"
KUBELET_CONFIG="/etc/systemd/system/kubelet.service.d/10-kubeadm.conf"
if [ ! -f "$KUBELET_CONFIG" ]; then
  KUBELET_CONFIG="/lib/systemd/system/kubelet.service.d/10-kubeadm.conf"
fi
awk -v pid="--provider-id=${PROVIDER_ID}" '/ExecStart=/ {count++; if(count==2) {sub(/$/, " " pid)} }1' $KUBELET_CONFIG > /tmp/kublet.conf && mv /tmp/kublet.conf $KUBELET_CONFIG
systemctl daemon-reload
NODETYPE=$(aws ec2 describe-instances --instance-id ${INSTANCE_ID} --query "Reservations[0].Instances[0].Tags[?Key=='NodeType'].Value" --output text --region ${AWS_REGION})
if [[ "${NODETYPE}" == "Master" ]]; then
	SecretList=$(aws secretsmanager list-secrets --filter Key="name",Values=${JOIN_SECRET} --query SecretList --region ${AWS_REGION})
	if [[ ${SecretList} == "[]" ]]
	then
	  aws secretsmanager create-secret --name ${JOIN_SECRET} --secret-string "{\"instanceId\":\"${INSTANCE_ID}\"}" --region ${AWS_REGION}
#	  CERT_KEY=$(kubeadm certs certificate-key)
	  kubeadm init --apiserver-advertise-address=${IP_ADDRESS} --apiserver-cert-extra-sans=${IP_ADDRESS} --control-plane-endpoint=${IP_ADDRESS}:6443
 	  export KUBECONFIG=/etc/kubernetes/admin.conf
	  kubectl apply -f https://github.com/weaveworks/weave/releases/download/v2.8.1/weave-daemonset-k8s.yaml
	  TOKEN=$(kubeadm token create)
	  HASH=$(kubeadm token create --print-join-command | sed 's/.*://')
    aws secretsmanager update-secret --secret-id ${JOIN_SECRET} --secret-string "{\"instanceId\":\"${INSTANCE_ID}\", \"IPadress\":\"${IP_ADDRESS}\", \"Token\":\"${TOKEN}\", \"Hash\":\"${HASH}\"}" --region ${AWS_REGION}
    if [ $? -eq 0 ]; then
      aws ec2 create-tags --resources ${INSTANCE_ID} --tags 'Key="Status",Value="SecretCreated" '
    else
      aws ec2 create-tags --resources ${INSTANCE_ID} --tags 'Key="Status",Value="NOT Created" '
    fi
    sed -i '0,/name: kubernetes/s//name: '${CLUSTERNAME}'/' /etc/kubernetes/admin.conf
    sed -i '0,/cluster: kubernetes/s//cluster: '${CLUSTERNAME}'/' /etc/kubernetes/admin.conf
#    sed -i '0,/'${IP_ADDRESS}'/s//'${DNS_NAME}'/' /etc/kubernetes/admin.conf
    CONFIG_SECRET="/${CLUSTERNAME}/kubernetes/config"
    aws secretsmanager create-secret --name ${CONFIG_SECRET} --secret-string file:///etc/kubernetes/admin.conf --region ${AWS_REGION}
    if [ $? -eq 0 ]; then
      aws ec2 create-tags --resources ${INSTANCE_ID} --tags 'Key="CONFIG_SECRET",Value="SecretCreated" '
    else
      aws ec2 create-tags --resources ${INSTANCE_ID} --tags 'Key="CONFIG_SECRET",Value="NOT Created" '
    fi
    CERT_SECRET="/${CLUSTERNAME}/kubernetes/certificates"
    FRONT_PROXY_CA_CERT=$(cat /etc/kubernetes/pki/front-proxy-ca.crt | base64 -w 0)
    FRONT_PROXY_CA_KEY=$(cat /etc/kubernetes/pki/front-proxy-ca.key | base64 -w 0)
    SA_KEY=$(cat /etc/kubernetes/pki/sa.key | base64 -w 0)
    SA_PUB=$(cat /etc/kubernetes/pki/sa.pub | base64 -w 0)
    CA_CRT=$(cat /etc/kubernetes/pki/ca.crt | base64 -w 0)
    CA_KEY=$(cat /etc/kubernetes/pki/ca.key | base64 -w 0)
    ETCD_CA_KEY=$(cat /etc/kubernetes/pki/etcd/ca.key | base64 -w 0)
    ETCD_CA_CRT=$(cat /etc/kubernetes/pki/etcd/ca.crt | base64 -w 0)
    aws secretsmanager create-secret --name ${CERT_SECRET} --secret-string "{\"front_proxy_ca_crt\":\"${FRONT_PROXY_CA_CERT}\", \"front_proxy_ca_key\":\"${FRONT_PROXY_CA_KEY}\", \"sa_key\":\"${SA_KEY}\", \"sa_pub\":\"${SA_PUB}\", \"ca_key\":\"${CA_KEY}\", \"ca_crt\":\"${CA_CRT}\", \"etcd_ca_key\":\"${ETCD_CA_KEY}\", \"etcd_ca_crt\":\"${ETCD_CA_CRT}\"}"
	  if [ $? -eq 0 ]; then
      aws ec2 create-tags --resources ${INSTANCE_ID} --tags 'Key="CERT_SECRET",Value="SecretCreated" '
    else
      aws ec2 create-tags --resources ${INSTANCE_ID} --tags 'Key="CERT_SECRET",Value="NOT Created" '
    fi
	else
	  TOKEN=$(aws secretsmanager get-secret-value --secret-id ${JOIN_SECRET} --query SecretString --output text | jq -r '.Token')
	  HASH=$(aws secretsmanager get-secret-value --secret-id ${JOIN_SECRET} --query SecretString --output text | jq -r '.Hash')
	  MASTER_IP=$(aws secretsmanager get-secret-value --secret-id ${JOIN_SECRET} --query SecretString --output text | jq -r '.IPadress')
	  MASTER_ID=$(aws secretsmanager get-secret-value --secret-id ${JOIN_SECRET} --query SecretString --output text | jq -r '.instanceId')
#	  CERT_KEY=$(aws secretsmanager get-secret-value --secret-id ${JOIN_SECRET} --query SecretString --output text | jq -r '.CertKey')
    # get certificates
    CERT_SECRET="/${CLUSTERNAME}/kubernetes/certificates"
    mkdir -p /etc/kubernetes/pki/etcd
    aws secretsmanager get-secret-value --secret-id ${CERT_SECRET} --query SecretString --output text | jq -r '.front_proxy_ca_crt' | base64 -d > /etc/kubernetes/pki/front-proxy-ca.crt
    aws secretsmanager get-secret-value --secret-id ${CERT_SECRET} --query SecretString --output text | jq -r '.front_proxy_ca_key' | base64 -d > /etc/kubernetes/pki/front-proxy-ca.key
    aws secretsmanager get-secret-value --secret-id ${CERT_SECRET} --query SecretString --output text | jq -r '.sa_key' | base64 -d > /etc/kubernetes/pki/sa.key
    aws secretsmanager get-secret-value --secret-id ${CERT_SECRET} --query SecretString --output text | jq -r '.sa_pub' | base64 -d > /etc/kubernetes/pki/sa.pub
    aws secretsmanager get-secret-value --secret-id ${CERT_SECRET} --query SecretString --output text | jq -r '.ca_key' | base64 -d > /etc/kubernetes/pki/ca.key
    aws secretsmanager get-secret-value --secret-id ${CERT_SECRET} --query SecretString --output text | jq -r '.ca_crt' | base64 -d > /etc/kubernetes/pki/ca.crt
    aws secretsmanager get-secret-value --secret-id ${CERT_SECRET} --query SecretString --output text | jq -r '.etcd_ca_key' | base64 -d > /etc/kubernetes/pki/etcd/ca.key
    aws secretsmanager get-secret-value --secret-id ${CERT_SECRET} --query SecretString --output text | jq -r '.etcd_ca_crt' | base64 -d > /etc/kubernetes/pki/etcd/ca.crt

    #join master
	  kubeadm join phase preflight ${MASTER_IP}:6443 --discovery-token ${TOKEN} --discovery-token-ca-cert-hash sha256:${HASH} --control-plane
    kubeadm join phase control-plane-prepare certs ${MASTER_IP}:6443 --discovery-token ${TOKEN} --discovery-token-ca-cert-hash sha256:${HASH} --control-plane
    kubeadm join phase control-plane-prepare kubeconfig ${MASTER_IP}:6443 --discovery-token ${TOKEN} --discovery-token-ca-cert-hash sha256:${HASH} --control-plane
    kubeadm join phase control-plane-prepare control-plane
    kubeadm join phase kubelet-start ${MASTER_IP}:6443 --discovery-token ${TOKEN} --discovery-token-ca-cert-hash sha256:${HASH}
    kubeadm join phase control-plane-join etcd --control-plane
    kubeadm join phase control-plane-join mark-control-plane --control-plane
    if [ $? -eq 0 ]; then
      aws ec2 create-tags --resources ${INSTANCE_ID} --tags 'Key="Status",Value="Joined" '
    else
      aws ec2 create-tags --resources ${INSTANCE_ID} --tags 'Key="Status",Value="NOT Joined" '
    fi
	fi
elif [[ "${NODETYPE}" == "Worker" ]]; then
	TOKEN=$(aws secretsmanager get-secret-value --secret-id ${JOIN_SECRET} --query SecretString --output text | jq -r '.Token')
	HASH=$(aws secretsmanager get-secret-value --secret-id ${JOIN_SECRET} --query SecretString --output text | jq -r '.Hash')
	MASTER_IP=$(aws secretsmanager get-secret-value --secret-id ${JOIN_SECRET} --query SecretString --output text | jq -r '.IPadress')
	MASTER_ID=$(aws secretsmanager get-secret-value --secret-id ${JOIN_SECRET} --query SecretString --output text | jq -r '.instanceId')
	kubeadm join ${MASTER_IP}:6443 --token ${TOKEN} --discovery-token-ca-cert-hash sha256:${HASH}
  if [ $? -eq 0 ]; then
    aws ec2 create-tags --resources ${INSTANCE_ID} --tags 'Key="Status",Value="Joined" '
  else
    aws ec2 create-tags --resources ${INSTANCE_ID} --tags 'Key="Status",Value="NOT Joined" '
  fi
fi


