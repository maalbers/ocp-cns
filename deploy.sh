#!/bin/bash
# Shell script to deploy OpenShift 3.6 on Microsoft Azure
# Magnus Glantz, sudo@redhat.com, 2017

# Assign first argument to be Azure Resource Group
GROUP=$1

# Test group variable
if test -z $GROUP; then
        echo "Usuage: $0 <unique name for Azure resource group>"
        exit 1
fi

OK=0
if [ -f ./deploy.cfg ]; then
	. ./deploy.cfg
	if test -z $OCP_USER; then
		OK=1
	elif test -z $OCP_PASSWORD; then
		OK=1
	elif test -z $RHN_ORGANIZATIONID; then
		OK=1
	elif test -z $RHN_ACTIVATIONKEY_INFRA; then
		OK=1
	elif test -z $RHN_ACTIVATIONKEY_CNODES; then
		OK=1
	elif test -z $LOCATION; then
		OK=1
        fi
        if test -z $MASTER_DNS; then
                MASTER_DNS="${GROUP}master"
                        if dig $MASTER_DNS.${LOCATION}.cloudapp.azure.com|grep -v ";"|grep "IN A"|awk '{ print $5 }'|grep [0-9] >/dev/null; then
                                echo "Error: $MASTER_DNS.${LOCATION}.cloudapp.azure.com already exists. Select other name."
                                exit 1
                        fi
	fi
        if test -z $INFRA_DNS; then
                INFRA_DNS="${GROUP}apps"
                        if dig $INFRA_DNS.${LOCATION}.cloudapp.azure.com|grep -v ";"|grep "IN A"|awk '{ print $5 }'|grep [0-9] >/dev/null; then
                                echo "Error: $INFRA_DNS.${LOCATION}.cloudapp.azure.com already exists. Select other name."
                                exit 1
                        fi
	fi
	if test -z $KEYVAULTRESOURCEGROUP; then
		KEYVAULTRESOURCEGROUP=${GROUP}
	fi
	if test -z $KEYVAULTNAME; then
		KEYVAULTNAME=${GROUP}KeyVaultName
	fi
	if test -z $KEYVAULTSECRETNAME; then
		KEYVAULTSECRETNAME=${GROUP}SecretName
	fi
	if test -z "$PUBLIC_SSH_KEY"; then
		if [ -f ~/.ssh/id_rsa.pub ]; then
			PUBLIC_SSH_KEY="$(cat ~/.ssh/id_rsa.pub)"
			echo "Your public key at ~/.ssh/id_rsa.pub is:"
			echo "$PUBLIC_SSH_KEY"
		else
			echo "No SSH key found in ~/.ssh/id_rsa.pub. Generating key."
			ssh-keygen
			PUBLIC_SSH_KEY="$(cat ~/.ssh/id_rsa.pub)"
			echo "Your key is:"
			echo "$PUBLIC_SSH_KEY"
		fi
		read -p "Do you want to use this key to access your azure VMs? (y/n)" ANSWER
		case $ANSWER in
			n|N)
				echo "Please fill in your public ssh key in deploy.cfg."
				exit 1
			;;
		esac
	fi
else
	OK=1
fi

if [ "$OK" -eq 1 ]; then
	echo "Missing variable values: Edit the deploy.cfg file"
	exit 1
fi

echo "Generating deployment configuration."
cat > azuredeploy.parameters.json << EOF
{
        "$schema": "http://schema.management.azure.com/schemas/2015-01-01/deploymentParameters.json#",
        "contentVersion": "1.0.0.0",
        "parameters": {
                "_artifactsLocation": {
                        "value": "https://raw.githubusercontent.com/maalbers/ocp-cns/Final/"
                },
                "masterVmSize": {
                        "value": "Standard_DS4_v2"
		},
                "infraVmSize": {
                        "value": "Standard_DS3_v2"	
                },
                "nodeVmSize": {
                        "value": "Standard_DS2_v2"
                },
                "openshiftClusterPrefix": {
                        "value": "ocp"
                },
		"openshiftMasterPublicIpDnsLabel": {
			"value": "$MASTER_DNS"
		},
		"infraPublicLbPublicIpDnsLabel": {
			"value": "${INFRA_DNS}p"
		},
		"infraRestrictedLbPublicIpDnsLabel": {
			"value": "${INFRA_DNS}r"
		},
		"masterInstanceCount": {
			"value": $MASTERCOUNT
		},
		"infraInstanceCount": {
			"value": $INFRACOUNT
		},
		"testnodeInstanceCount": {
			"value": $TESTNODECOUNT
		},
		"prodnodeInstanceCount": {
			"value": $PRODNODECOUNT
		},
		"dataDiskSize": {
			"value": $DISKSIZE
		},
		"adminUsername": {
			"value": "$OCP_USER"
		},
		"openshiftPassword": {
			"value": "$OCP_PASSWORD"
		},
		"rhnOrganizationID": {
			"value": "$RHN_ORGANIZATIONID"
		},
		"rhnActivationKeyInfra": {
			"value": "$RHN_ACTIVATIONKEY_INFRA"
		},
		"rhnActivationKeyCNodes": {
			"value": "$RHN_ACTIVATIONKEY_CNODES"
		},
		"sshPublicKey": {
			"value": "$PUBLIC_SSH_KEY"
		},
		"keyVaultResourceGroup": {
			"value": "$KEYVAULTRESOURCEGROUP"
		},
		"keyVaultName": {
			"value": "$KEYVAULTNAME"
		},
		"keyVaultSecret": {
			"value": "$KEYVAULTSECRETNAME"
		},
		"defaultSubDomainType": {
			"value": "$DOMAINTYPE"
		},
		"defaultSubDomain": {
			"value": "$CUSTOMDOMAIN"
		}
	}
}
EOF

echo "Deploying OpenShift Container Platform."

# Create Azure Resource Group
azure group create $GROUP $LOCATION

# Create Keyvault in which we put our SSH private key
azure keyvault create -u ${GROUP}KeyVaultName -g $GROUP -l $LOCATION

# Put SSH private key in key vault
azure keyvault secret set -u ${GROUP}KeyVaultName -s ${GROUP}SecretName --file ~/.ssh/id_rsa

# Enable key vault to be used for deployment
azure keyvault set-policy -u ${GROUP}KeyVaultName --enabled-for-template-deployment true

# Launch deployment of cluster, after this it’s just waiting for it to complete. 
# azuredeploy.parameters.json needs to be populated with valid values first, before you run this.
azure group deployment create --name ${GROUP} --template-file azuredeploy.json -e azuredeploy.parameters.json --resource-group $GROUP --nowait

echo
echo "Deployment initiated. Allow 40-50 minutes for a deployment to succeed."
echo "The cluster will be reachable at https://$MASTER_DNS.${LOCATION}.cloudapp.azure.com:8443"
echo
echo "Waiting for Bastion host IP to get allocated."

while true; do
	if azure network public-ip show $GROUP bastionpublicip|grep "IP Address"|cut -d':' -f3|grep [0-9] >/dev/null; then
		break
	else
		sleep 5
	fi
done

echo "You can SSH into the cluster by accessing it's bastion host: ssh $(azure network public-ip show $GROUP bastionpublicip|grep "IP Address"|cut -d':' -f3|grep [0-9]|sed 's/ //g')"
echo "Once your SSH key has been distributed to all nodes, you can then jump passwordless from the bastion host to all nodes."
echo "To SSH directly to the master, use port 2200: ssh $MASTER_DNS.${LOCATION}.cloudapp.azure.com -p 2200"
echo "For troubleshooting, check out /var/lib/waagent/custom-script/download/[0-1]/stdout or stderr on the nodes"




