#!/bin/bash

################################################################
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Licensed Materials - Property of IBM
#
# ©Copyright IBM Corp. 2021
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Last updated: 13/09/2021
#
################################################################

# docs link https://github.com/IBM/cpd-cli/releases
# docs link https://github.com/IBM/cpd-cli/tree/master/cpdbr

choice=$1
if [[ -z ${choice} ]]; then
    echo "What do you want to do?"
    echo "  1- setup cluster"
    echo "  2- init"
    echo "  3- backup"
    echo "  4- restore"
    echo "  5- quiesce"
    echo "  6- unquiesce"
    echo "  7- unquiesce force"
    echo "  9- uninstall"
    echo "  q to quit"
    read -p 'Choice number: ' choice
fi

INSTALL_NAMESPACE=zen
#ARCH=ppc64le
ARCH=linux
#LOG_LEVEL=info
LOG_LEVEL=debug
#SKIP_QUIESCE=false
SKIP_QUIESCE=true

function setup_backup_restore () { 
	rm -rf ./cpd-cli* LICENSES plugins
	wget https://github.com/IBM/cpd-cli/releases/download/v10.0.1/cpd-cli-${ARCH}-EE-10.0.1.tgz
        tar xvf cpd-cli-${ARCH}-EE-10.0.1.tgz
        mv cpd-cli-${ARCH}-EE-10.0.1*/* .
#	oc patch configs.imageregistry.operator.openshift.io/cluster --patch '{"spec":{"defaultRoute":true}}' --type=merge
#	sleep 30
        IMAGE_REGISTRY=$(oc get route -n openshift-image-registry | grep image-registry | awk '{print $2}')
	echo ${IMAGE_REGISTRY}
	CPU_ARCH=$(uname -m)
	echo ${CPU_ARCH}
	BUILD_NUM=$(./cpd-cli backup-restore version | grep -m1 "Build Number" |cut -d : -f 2 | xargs)
	echo ${BUILD_NUM}
	echo "Install podman if it is not installed"
	which podman
	if [[ $? != 0 ]]; then
		yum install -y podman
	fi
  echo "Pull cpdbr image from Docker Hub"
	podman pull docker.io/ibmcom/cpdbr:4.0.0-${BUILD_NUM}-${CPU_ARCH}
	echo "Push image to internal registry"
	podman login -u kubeadmin -p $(oc whoami -t) ${IMAGE_REGISTRY} --tls-verify=false
	podman tag docker.io/ibmcom/cpdbr:4.0.0-${BUILD_NUM}-${CPU_ARCH} ${IMAGE_REGISTRY}/${INSTALL_NAMESPACE}/cpdbr:4.0.0-${BUILD_NUM}-${CPU_ARCH}
	podman push ${IMAGE_REGISTRY}/${INSTALL_NAMESPACE}/cpdbr:4.0.0-${BUILD_NUM}-${CPU_ARCH} --tls-verify=false
	echo "Create backup persistent volume"
	oc create -f - << EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: cpdbr-pvc
spec:
  storageClassName: nfs-client
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 200Gi
EOF

	echo "Create backup repository secret"
	echo -n 'restic' > RESTIC_PASSWORD
	oc create secret generic -n ${INSTALL_NAMESPACE} cpdbr-repo-secret --from-file=./RESTIC_PASSWORD
}

function init () {
	echo "Initialize backup process"
	./cpd-cli backup-restore init -n  ${INSTALL_NAMESPACE} --log-level=${LOG_LEVEL} --verbose --pvc-name cpdbr-pvc --image-prefix=image-registry.openshift-image-registry.svc:5000/${INSTALL_NAMESPACE}  --provider=local
	sleep 60
}


function backup () {
        # we run the init function before, just to make sure.
	init
	echo "Start backup"
	./cpd-cli backup-restore volume-backup create -n ${INSTALL_NAMESPACE} --skip-quiesce=${SKIP_QUIESCE} ${INSTALL_NAMESPACE}-volbackup01 --log-level=${LOG_LEVEL} --verbose
	sleep 30
	echo "Check backup status"
	./cpd-cli backup-restore volume-backup status -n ${INSTALL_NAMESPACE} ${INSTALL_NAMESPACE}-volbackup01
#output:
#Volume:         zen-volbackup01
#Job Name:       cpdbr-bu-zen-volbackup01
#Active:         0
#Succeeded:      1
#Failed:         0
#Start Time:     Sun, 12 Sep 2021 15:47:51 +0100
#Completed At:   Sun, 12 Sep 2021 15:51:38 +0100
#Duration:       3m47s
	echo "list backup volumes"
	./cpd-cli backup-restore volume-backup list -n ${INSTALL_NAMESPACE}
#output:
#NAME            CREATED AT              LAST BACKUP
#zen-volbackup01 2021-09-12T14:47:55Z    2021-09-12T14:51:38Z
}

function restore () {
	echo "Starting restore process"
	echo "Remove cpdbr-bu-${INSTALL_NAMESPACE}-volbackup01 job"
	oc delete job cpdbr-bu-${INSTALL_NAMESPACE}-volbackup01
	echo "Unlock volume to be used in restore"
	./cpd-cli backup-restore volume-backup unlock ${INSTALL_NAMESPACE}-volbackup01 -n ${INSTALL_NAMESPACE} --log-level=${LOG_LEVEL} --verbose
	echo "Restore from backup volume"
	./cpd-cli backup-restore volume-restore create -n  ${INSTALL_NAMESPACE} --from-backup ${INSTALL_NAMESPACE}-volbackup01 --skip-quiesce=${SKIP_QUIESCE} ${INSTALL_NAMESPACE}-volrestore1 --log-level=${LOG_LEVEL} --verbose
        # if it fails remove the cpdbur job that use the pvc, then try again
	echo "check the volume restore job status for ${INSTALL_NAMESPACE} namespace"
	./cpd-cli backup-restore volume-restore status -n ${INSTALL_NAMESPACE}  ${INSTALL_NAMESPACE}-volrestore1
	echo "list volume restores for ${INSTALL_NAMESPACE} namespace"
	./cpd-cli backup-restore volume-restore list -n ${INSTALL_NAMESPACE}
}

function quiesce () {
	./cpd-cli backup-restore quiesce -n ${INSTALL_NAMESPACE} --log-level=${LOG_LEVEL} --verbose
}

function unquiesce () {
	./cpd-cli backup-restore unquiesce -n ${INSTALL_NAMESPACE} --log-level=${LOG_LEVEL} --verbose
}

function unquiesce_ignore_hooks () {
	./cpd-cli backup-restore unquiesce -n ${INSTALL_NAMESPACE} --ignore-hooks --log-level=${LOG_LEVEL} --verbose
}

function force_reset () {
	echo "Resetting cpdbr. This will:"
        echo "1. uninstall the cpdbr application from the ${INSTALL_NAMESPACE} namespace"
        echo "2. delete the backup storage volume"
        echo "3. delete the backup repository secret"
        echo "4. uninstall cdp-cli"
        while true; do
          read -p "DO YOU REALLY WANT TO CONTINUE?" yn
          case $yn in
            [Yy]* ) break;;
            [Nn]* ) exit;;
            * ) echo "Please answer yes or no.";;
          esac
        done
	./cpd-cli backup-restore reset -n ${INSTALL_NAMESPACE} --force --log-level=${LOG_LEVEL} --verbose
        oc delete pvc cpdbr-pvc
        oc delete secret cpdbr-repo-secret
	rm -rf ./cpd-cli* LICENSES plugins ./RESTIC_PASSWORD
}

case $choice in
	1)
    setup_backup_restore
		;;
	2)
		init
		;;
	3)
		backup
		;;
	4)
		restore
		;;
	5)
		quiesce
		;;
	6)
		unquiesce
		;;
	7)
		unquiesce_ignore_hooks
		;;
	9)
		force_reset
		;;
	q)
		echo "existing backup script"
		exit 0
		;;
	*)
		echo "invalid choice"
		;;
esac
