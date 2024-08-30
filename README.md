# ShellScripts
Repo that contains handy shell scripts

# kubeadm_master_worker_setup
This script installs aws cli, configures ipv4 forwarding, installs containerd, runc, cni-plugins, crictl, kubeadm, kubelet and kubectl on AWS EC2 Ubuntu instance.
It also initializes cluster on instance if it has "NodeType = Master" tag and stores values needed for workers to join in AWS Secret, 
or joines a node if the instances has "NodeType = Worker" tag.

