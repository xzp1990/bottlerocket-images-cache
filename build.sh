#!/bin/bash

if [ "$#" -ne 2  ] ; then
    echo "usage: $0 [sd_svc_image_url] [subnet]"
    exit 1
fi

sd_svc_image_url=$1
subnet=$2
# subnet=subnet-020ee6a321708b096
region=ap-northeast-1

echo "./r_snapshot.sh -r $region -i g5.xlarge -s ${subnet} ${region} -a /aws/service/bottlerocket/aws-k8s-1.25-nvidia/x86_64/latest/image_id ${sd_svc_image_url}"
bash ./r_snapshot.sh -r $region -i g5.xlarge -s ${subnet} ${region} -a /aws/service/bottlerocket/aws-k8s-1.25-nvidia/x86_64/latest/image_id ${sd_svc_image_url}
