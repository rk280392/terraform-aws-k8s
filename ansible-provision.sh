#!/bin/bash
#shopt -s expand_aliases

if [[ "$1" == "banner" ]]; then
   sed -i "/:6443/s/https:.*/https:\/\/$2:6443/g" config
   echo '####################################################################################################################################'
   echo -e 'Congratualations your cluster is ready. You can set an alias using `alias k="kubectl --kubeconfig=config"` in the same directory'
   echo '####################################################################################################################################'
   helm install --kubeconfig=config flannel https://github.com/flannel-io/flannel/releases/latest/download/flannel.tgz -n kube-system
   kubectl --kubeconfig=config apply -f components.yaml
else
   export ANSIBLE_HOST_KEY_CHECKING=False
   nc -z "$1" 22
   while [ $? -ne 0 ]
   do 
      echo "checking if port is open"
      nc -z "$1" 22
   done

   echo "Executing ansible script with values  -i $1 nodeip=$2 --skip-tags $3 nodepubip=$1"
   ansible-playbook -u ubuntu --private-key kubernetes-terraform.pem -i $1, master-playbook.yaml  --extra-vars "nodeip=$2" --extra-vars "hostname=$4" --skip-tags "$3" --extra-vars "nodepubip=$5"
fi


