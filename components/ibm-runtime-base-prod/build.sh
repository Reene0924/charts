#!/bin/bash
# To make the WS 2.0 Base helm chart
#
set -e
CUR_DIR=$(cd $(dirname $0); pwd 2>/dev/null)
PKG_NAME="ibm-runtime-base-prod"
PKG_TAG=$(awk '{for(i=1;i<=NF;i++) if ($i=="version:") print $(i+1)}' ${CUR_DIR}/Chart.yaml)
CONFIG_FILE="ws-base"
CONFIG_FILE_PATH="${CUR_DIR}/../../../InstallAndGo/config_files/${CONFIG_FILE}.txt"
PKG_DIR=${PKG_NAME}
TMP_DIR="${WORKSPACE}/tmp/untarLoadPush"
ARCH=$(uname -m)
# change architecture
if [ $ARCH != "x86_64" ]; then
   sed -i  "s#architecture: \"amd64\"#architecture: \"$(uname -m)\"#g" ${CUR_DIR}/values.yaml
fi

# Function to untar the service tar.gz and load the image and push
# Parameter is the tar file name, must be an absolute path
function untar_load_push() {
    local filename="$(basename $1)"
    local dirname="$(dirname $1)"
    local svcname="$(echo ${filename} | cut -d. -f1)"
    local diruntar="${dirname}/${svcname}-artifact"
    echo "Service ${svcname} Untaring ${filename}"

    local cmd="tar -zxvf ${1} -C ${dirname}"
    echo "$cmd"
    eval "$cmd"

    if [[ ! -d "${diruntar}" ]]; then
        echo "Directory ${diruntar} does not exist"
        exit 1
    fi

    imgs=($(ls ${diruntar} |  grep 'tar.gz$' ))
    previousDir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
    cd ${diruntar}
    for cur_img in ${imgs[@]}; do
        echo "Removing localhost:5000/ prefix for ${cur_img}"
        python ${CUR_DIR}/../../remove_image_prefix.py ./${cur_img} "localhost:5000/"
        mv ./${cur_img::-7}/${cur_img} ${CUR_DIR}/../images/${cur_img}
    done
    cd ${previousDir}
}

# Make sure docker client does exist
which docker

# Copy service to the directory - This script is checked out by the jenkins job from InstallAndGo
echo "Updating the images"

CUR_DIR_2="${WORKSPACE}/InstallAndGo/build/"
cd ${CUR_DIR_2}
SETTING_FILE_PATH="${CUR_DIR_2}/../config_files/settings.sh"

rm -rf ../config_files

mkdir -p ${CUR_DIR_2}/../config_files


mkdir -p ${CUR_DIR}/../InstallAndGo/config_files


mkdir -p ${CUR_DIR}/../../../InstallAndGo/config_files
if [ $ARCH = "ppc64le" ]; then
    echo "#Service||Repo||Branch||Namespace||Jenkins||Jenkins Branch Name||project build machine||path" > ${CONFIG_FILE_PATH}
    echo "spawner-go-api||PrivateCloud/spawner-go-api||${spawnerApiBranch}||ibm-private-cloud||DSXL-Trigger-spawner-go-api-power||BR:spawnerApiBranch||9.30.4.45||.." >> ${CONFIG_FILE_PATH}
    echo "hi-proxy-pod||PrivateCloud/dsx-integration||${dsxIntegrationBranch}||ibm-private-cloud||DSXL-Trigger-hi-proxy-pod-power||BR:dsxIntegrationBranch||9.30.4.45||.." >> ${CONFIG_FILE_PATH}
    echo "utils-api||PrivateCloud/utils-api||ws-dev||ibm-private-cloud||WS-Trigger-utils-api-2.0-power||BR:utilsApiBranch||9.30.4.45||.." >> ${CONFIG_FILE_PATH}
    echo "ha-proxy-hi||PrivateCloud/utils-api||ws-dev||ibm-private-cloud||WS-Trigger-HA-Proxy-HI-Power||BR:utilsApiBranch||9.30.4.45||.." >> ${CONFIG_FILE_PATH}
else
    echo "#Service||Repo||Branch||Namespace||Jenkins||Jenkins Branch Name||project build machine||path" > ${CONFIG_FILE_PATH}
    echo "spawner-go-api||PrivateCloud/spawner-go-api||${spawnerApiBranch}||ibm-private-cloud||DSXL-Trigger-spawner-go-api||BR:spawnerApiBranch||9.30.4.45||.." >> ${CONFIG_FILE_PATH}
    echo "hi-proxy-pod||PrivateCloud/dsx-integration||${dsxIntegrationBranch}||ibm-private-cloud||DSXL-Trigger-hi-proxy-pod||BR:dsxIntegrationBranch||9.30.4.45||.." >> ${CONFIG_FILE_PATH}
    echo "utils-api||PrivateCloud/utils-api||ws-dev||ibm-private-cloud||WS-Trigger-utils-api-2.0||BR:utilsApiBranch||9.30.4.45||.." >> ${CONFIG_FILE_PATH}
    echo "ha-proxy-hi||PrivateCloud/utils-api||ws-dev||ibm-private-cloud||WS-Trigger-HA-Proxy-HI||BR:utilsApiBranch||9.30.4.45||.." >> ${CONFIG_FILE_PATH}
fi

cat << EOF > ${SETTING_FILE_PATH}
#!/bin/bash
DEFAULT_JENKINS_DIR=/zpool1/disk1
EOF

# get the tar files
${CUR_DIR}/../../../InstallAndGo/build/copyServices.sh ${CONFIG_FILE} "../ws-v2-base-charts/charts/services"
if [[ $? -ne 0 ]]
then
    echo "Build fail, cannot get build artifact"
    exit 1
fi
cd ${CUR_DIR}

# Handling each service
mkdir -p ${CUR_DIR}/../images
mkdir -p ${TMP_DIR}

files=($(ls ${CUR_DIR}/../services))
for cur_file in ${files[@]}; do
    # Depends on the jobs output, we allow only 5 jobs at a time
    while [[ 1 ]]; do
        [[ $(jobs -rp | wc -l) -lt 5 ]] && break
        sleep 5
    done

    out=$(mktemp -p ${TMP_DIR} ws.out.XXXXXXXXXXXX)

    untar_load_push ${CUR_DIR}/../services/${cur_file} > ${out} 2>&1 &

done
wait

# Do clean up none images in background as we do not care result
docker image prune -f &

# Update the values.yaml for the image version according to image .tar.gz file name

sh ${CUR_DIR}/update_value_yaml.sh
[[ $? -ne 0 ]] && exit 1

rm -rf  ${CUR_DIR}/update_value_yaml.sh ${CUR_DIR}/build.sh

# Update version number with build number
sed -i "s/version: 3.0.0/version: 3.0.${BUILD_NUMBER}/g" ${CUR_DIR}/Chart.yaml
sed -i "s/appVersion: 3.0.0/appVersion: 3.0.${BUILD_NUMBER}/g" ${CUR_DIR}/Chart.yaml

# Build now
echo "Make the chart now"
cd ${CUR_DIR}/..

if [ $ARCH = "x86_64" ]; then
    curl -H "X-JFrog-Art-Api:${ARTIFACTORY_PASSWORD}" -O "https://na.artifactory.swg-devops.com/artifactory/hyc-dsxl-build-generic-local/icp_helm/helm-v2.9.1-linux-amd64.tar.gz"
    tar xzvf helm-v2.9.1-linux-amd64.tar.gz
    HELM_DIR=${CUR_DIR}/../linux-amd64
elif [ $ARCH = "ppc64le" ]; then
    wget -q "https://storage.googleapis.com/kubernetes-helm/helm-v2.12.2-linux-ppc64le.tar.gz"
    tar xzvf helm-v2.12.2-linux-ppc64le.tar.gz
    HELM_DIR=${CUR_DIR}/../linux-ppc64le
fi

${HELM_DIR}/helm init --client-only
${HELM_DIR}/helm repo add --username ${ARTIFACTORY_EMAIL} --password ${ARTIFACTORY_PASSWORD} icpdata https://na.artifactory.swg-devops.com/artifactory/hyc-icp-data-helm-virtual
${HELM_DIR}/helm package -u ${PKG_NAME}


chmod u+x ${CUR_DIR}/createModule.sh
sh ${CUR_DIR}/createModule.sh

ARTIFACT=${PKG_NAME}-${ARCH}.tar
echo $ARTIFACT

rm -rf ${PKG_DIR}
mkdir ${PKG_DIR}
mkdir -p ${PKG_DIR}/charts
mv ${PKG_NAME}-*.tgz ${PKG_DIR}/charts
mv images ${PKG_DIR}
touch icp4d-override.yaml
touch icp4d-metadata.yaml
mv icp4d-override.yaml ${PKG_DIR}
mv icp4d-metadata.yaml ${PKG_DIR}

tar -cvf ${WORKSPACE}/${ARTIFACT} ${PKG_DIR}
cd ${WORKSPACE}
if [[ ${PUSH_TO_FILESERVER} = 'TRUE' ]]; then
  echo "uploading artifacts to the file server icpfs1.svl.ibm.com"
  runtimeBaseFolder="/pool1/data1/zen/cp4d-builds/3.0.1/local/components/common-core-services/modules/runtime-base"
  VersionFileLocation=${runtimeBaseFolder}/${ARCH}/versions.yaml
  sshpass -p $fileServerPassword scp -r -o StrictHostKeyChecking=no 3.0.${BUILD_NUMBER} build@icpfs1.svl.ibm.com:${runtimeBaseFolder}/${ARCH}
  sshpass -p $fileServerPassword scp -r -o StrictHostKeyChecking=no build@icpfs1.svl.ibm.com:${VersionFileLocation} .
  echo "  - 3.0.${BUILD_NUMBER}" >> versions.yaml
  sshpass -p $fileServerPassword scp -r -o StrictHostKeyChecking=no versions.yaml build@icpfs1.svl.ibm.com:${VersionFileLocation}
fi
exit $?
