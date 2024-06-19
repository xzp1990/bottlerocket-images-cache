#!/bin/bash
set -e

##############################################################################################
#sample command from eks 1.29 GPU stable diffusion project - by Jason Xie
# ./r_snapshot.sh -r us-west-2 -i g5.xlarge -s subnet-019a95825641bc28c -a /aws/service/bottlerocket/aws-k8s-1.29-nvidia/x86_64/latest/image_id 970662323538.dkr.ecr.us-west-2.amazonaws.com/sd-game-activty:latest
# the script use default ec2 security gropu, please make sure the SG have internet outbound access.
# Retrieve ami:
# aws ssm get-parameter --name /aws/service/bottlerocket/aws-k8s-1.29/x86_64/latest/image_id --region region-code --query "Parameter.Value" --output text
##############################################################################################

function print_help {
    echo "usage: $0 [options] <comma seperated container images>"
    echo "Build EBS snapshot for Bottlerocket data volume with cached container images"
    echo "Options:"
    echo "-h,--help print this help"
    echo "-r,--region Set AWS region to build the EBS snapshot, (default: use environment variable of AWS_DEFAULT_REGION)"
    echo "-a,--ami Set SSM Parameter path for Bottlerocket ID, (default: /aws/service/bottlerocket/aws-k8s-1.21/x86_64/latest/image_id)"
    echo "-i,--instance-type Set EC2 instance type to build this snapshot, (default: t2.small)"
    echo "-s,--subnet Set where to host EC2 instance"
    echo "-c,--clean Set whether to clean existing images"
}

while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -h|--help)
            print_help
            exit 1
            ;;
        -r|--region)
            AWS_DEFAULT_REGION=$2
            shift
            shift
            ;;
        -a|--ami)
            AMI_ID=$2
            shift
            shift
            ;;
        -i|--instance-type)
            INSTANCE_TYPE=$2
            shift
            shift
            ;;
        -s|--subnet)
            SUBNET_ID=$2
            shift
            shift
            ;;
        -c|--clean)
            IS_CLEAN=$2
            shift
            shift
            ;;                        
        *)    # unknown option
            POSITIONAL+=("$1") # save it in an array for later
            shift # past argument
            ;;
    esac
done

set +u
set -- "${POSITIONAL[@]}" # restore positional parameters
IMAGES="$2"
set -u

AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-}
AMI_ID=${AMI_ID:-/aws/service/bottlerocket/aws-k8s-1.25/x86_64/latest/image_id}
INSTANCE_TYPE=${INSTANCE_TYPE:-t2.small}
SUBNET_ID=${SUBNET_ID}
IS_CLEAN=${IS_CLEAN:-false}
CTR_CMD="apiclient exec admin sheltie ctr -a /run/containerd/containerd.sock -n k8s.io"

if [ -z "${AWS_DEFAULT_REGION}" ]; then
    echo "Please set AWS region"
    exit 1
fi

if [ -z "${IMAGES}" ]; then
    echo "Please set images list"
    exit 1
fi

if [ -z "${SUBNET_ID}" ]; then
    echo "Please set subnet"
    exit 1
fi

IMAGES_LIST=(`echo $IMAGES | sed 's/,/\n/g'`)
export AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION}

##############################################################################################
export AWS_PAGER=""

# launch EC2 - for stable diffusion requirement, make sure you have 120GB gp3 data store. k8s的image是4G(/dev/xvda) 18G(/dev/xvdb) - 待修改
echo "[1/8] Deploying EC2 CFN stack ..."
CFN_STACK_NAME="Bottlerocket-ebs-snapshot"
aws cloudformation deploy --stack-name $CFN_STACK_NAME --template-file ebs-snapshot-instance.yaml --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides SubnetID=$SUBNET_ID AmiID=$AMI_ID InstanceType=$INSTANCE_TYPE
INSTANCE_ID=$(aws cloudformation describe-stacks --stack-name $CFN_STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text)
echo INSTANCE_ID=$INSTANCE_ID

# wait for SSM ready
echo -n "[2/8] Launching SSM ."
while [[ $(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$INSTANCE_ID" --query "InstanceInformationList[0].PingStatus" --output text) != "Online" ]]
do
   echo -n "."
   sleep 5
done
echo " done!"

# stop kubelet.service
echo -n "[3/8] Stopping kubelet.service .."
CMDID=$(aws ssm send-command --instance-ids $INSTANCE_ID \
    --document-name "AWS-RunShellScript" --comment "Stop kubelet" \
    --parameters commands="apiclient exec admin sheltie systemctl stop kubelet" \
    --query "Command.CommandId" --output text)
aws ssm wait command-executed --command-id "$CMDID" --instance-id $INSTANCE_ID > /dev/null
echo " done!"

# cleanup existing images
# echo -n "[4/8] Cleanup existing images .."
# CMDID=$(aws ssm send-command --instance-ids $INSTANCE_ID \
#     --document-name "AWS-RunShellScript" --comment "Cleanup existing images" \
#     --parameters commands="$CTR_CMD images rm \$($CTR_CMD images ls -q)" \
#     --query "Command.CommandId" --output text)
# aws ssm wait command-executed --command-id "$CMDID" --instance-id $INSTANCE_ID > /dev/null
# echo " done!"
if [ ${IS_CLEAN} ]; then
    echo -n "[4/8] Cleanup existing images .."
    CMD_CLEAN_ID=$(aws ssm send-command --instance-ids $INSTANCE_ID \
            --document-name "AWS-RunShellScript" --comment "Clean Existing Images" \
            --parameters commands="apiclient exec admin sheltie ctr -n k8s.io images rm \$(apiclient exec admin sheltie ctr -n k8s.io images ls -q)" \
            --cloud-watch-output-config "CloudWatchOutputEnabled=true" \
            --query "Command.CommandId" --output text)
    #wait的命令默认只会等100s,对于大模型是不够的。
    #aws ssm wait command-executed --command-id "$CMD_CLEAN_ID" --instance-id $INSTANCE_ID > /dev/null && echo "clean done"
    aws ssm wait command-executed --command-id "$CMD_CLEAN_ID" --instance-id $INSTANCE_ID > /dev/null && echo "clean done"
else
    echo -n "[4/8] Keep existing images, do nth .."   
fi
echo " done!"

# pull images
echo "[5/8] Pulling ECR images:"
for IMG in "${IMAGES_LIST[@]}"
do
    ECR_REGION=$(echo $IMG | sed -n "s/^[0-9]*\.dkr\.ecr\.\([a-z1-9-]*\)\.amazonaws\.com.*$/\1/p")
    [ ! -z "$ECR_REGION" ] && ECRPWD="--u AWS:"$(aws ecr get-login-password --region $ECR_REGION) || ECRPWD=""
    #if you need more platform, you can add arm64 (如果需要其它platform, 可以加加arm64)
    for PLATFORM in amd64
    do
        echo -n "  $IMG - $PLATFORM .."
        CMDID=$(aws ssm send-command --instance-ids $INSTANCE_ID \
            --document-name "AWS-RunShellScript" --comment "Pull Images" \
            --parameters commands="apiclient exec admin sheltie ctr -a /run/dockershim.sock -n k8s.io images pull --platform $PLATFORM $IMG $ECRPWD" \
            --query "Command.CommandId" --output text)
        
        #wait的命令默认只会等100s,对于大模型是不够的,所以修改成阻塞型实现
        #aws ssm wait command-executed --command-id "$CMDID" --instance-id $INSTANCE_ID > /dev/null && echo "pull done"
        while [[ $(aws ssm get-command-invocation --command-id  "$CMDID" --instance-id $INSTANCE_ID --query "Status" --output text) != "Success" ]]
        do
           echo -n "."
           sleep 5
        done
        echo -n "- pull image done."
        echo ""
    done
done
echo " done."

# stop EC2
echo -n "[6/8] Stopping instance ... "
aws ec2 stop-instances --instance-ids $INSTANCE_ID --output text > /dev/null
aws ec2 wait instance-stopped --instance-ids "$INSTANCE_ID" > /dev/null && echo "done!"

# create EBS snapshot
echo -n "[7/8] Creating snapshot ... "
DATA_VOLUME_ID=$(aws ec2 describe-instances  --instance-id $INSTANCE_ID --query "Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName=='/dev/xvdb'].Ebs.VolumeId" --output text)
SNAPSHOT_ID=$(aws ec2 create-snapshot --volume-id $DATA_VOLUME_ID --description "Bottlerocket Data Volume snapshot" --query "SnapshotId" --output text)
#aws ec2 wait snapshot-completed --snapshot-ids "$SNAPSHOT_ID" > /dev/null && echo "done!"
while true; do
    status=$(aws ec2 describe-snapshots --snapshot-ids "$SNAPSHOT_ID" --query 'Snapshots[0].State' --output text)
    if [ "$status" == "completed" ]; then
        echo "Snapshot $SNAPSHOT_ID completed successfully."
        break
    else
        echo -n "."
        sleep 5
    fi
done


# aws ec2 enable-fast-snapshot-restores \
#     --availability-zones ${AWS_DEFAULT_REGION}a ${AWS_DEFAULT_REGION}b ${AWS_DEFAULT_REGION}c \
#     --source-snapshot-ids $SNAPSHOT_ID

# destroy temporary instance
echo "[8/8] Cleanup."
aws cloudformation delete-stack --stack-name "Bottlerocket-ebs-snapshot"

# done!
echo "--------------------------------------------------"
export EBS_SNAPSHOT_ID=$SNAPSHOT_ID
echo "All done! Created snapshot in $AWS_DEFAULT_REGION: $EBS_SNAPSHOT_ID"