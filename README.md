# ShellScripts
Repo that contains handy shell scripts

## kubeadm_master_worker_setup
This script installs aws cli, configures ipv4 forwarding, installs containerd, runc, cni-plugins, crictl, kubeadm, kubelet and kubectl on AWS EC2 Ubuntu instance.
It also initializes cluster on instance if it has "NodeType = Master" tag and stores values needed for workers to join in AWS Secret.
or joines a node if the instance has "NodeType = Worker" tag.

## mount_ebs_volume
This script attaches and mounts AWS EBS volumes (xvda and nvme) to mount location. It must be run with three arguments(ebsVolumeId, device, mount_dir). You have to have aws-cli and nvme-cli already installed on the EC2 Instance for this script to work.

