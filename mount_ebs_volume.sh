#!/bin/bash
############################################
# ./mount_ebs_volume.sh ebsVolumeId device mount_dir
#   ebsVolumeId - EBS volume id
#   device        - Device name as set in instance configuration
#   mount_dir          - Path to use as mount directory
#
# Requirements:
#   aws-cli
#   nvme-cli
#
# This script attaches and mounts EBS volumes (xvda and nvme) to mount location
###########################################

# Check for AWS CLI, if it's not installed exit the script, else run this script
AWS_CLI=$(aws --version)
if [[ $? -eq 1 ]]; then
  exit 1
else
  # Read arguments
  VOLUME_ID=${1}
  DEVICE_NAME=${2}
  MOUNT_DIR=${3}
  # echo passed arguments

  echo "VolumeId: ${VOLUME_ID}"
  echo "Device: ${DEVICE_NAME}"
  echo "Mount: ${MOUNT_DIR}"

  # Get instance id
  InstId=`curl http://169.254.169.254/latest/meta-data/instance-id`
  echo `curl http://169.254.169.254/latest/meta-data/instance-id` >> ./Mount.log

  # make mount directory if it doesn't exist
  if [ ! -d ${MOUNT_DIR} ]; then
      echo "Creating directory ${MOUNT_DIR} ..."
      mkdir -p ${MOUNT_DIR}
      if [ $? -ne 0 ]; then
          echo 'ERROR: Directory creation failed!'
          exit 1
      fi
  else
      echo "Directory ${MOUNT_DIR} already exists!"
  fi

  # Try to mount volume in a loop to compensate for attach delay
  i=0
  echo "########################" >> ./Mount.log
  echo "MOUNTING: ${DEVICE_NAME} - ${MOUNT_DIR}" >> ./Mount.log
  echo "########################" >> ./Mount.log
  echo " " >> ./Mount.log
  while [ $i -le 20 ]
  do
    echo "########################" >> ./Mount.log
    echo "TRY: $i" >> ./Mount.log
    echo TRY: $i
    InstId=`curl http://169.254.169.254/latest/meta-data/instance-id`
    echo `curl http://169.254.169.254/latest/meta-data/instance-id`
    # gets volume details (with volume id VOLUME_ID ) and writes output to /tmp/checkAttach1
    aws ec2 describe-volumes --volume-id ${VOLUME_ID} --region eu-central-1 > /tmp/checkAttach1
    sleep 3
  # Check if volume is already attached
    if grep -qs "InstanceId\": \"$InstId" /tmp/checkAttach1; then
      echo "Volume is attached already."
      echo "Volume is attached already." >> ./Mount.log
    else
      echo "attaching volume."
      echo "attaching volume." >> ./Mount.log
      # attaching volume on instance
      aws ec2 attach-volume --volume-id ${VOLUME_ID} --instance-id $InstId --device ${DEVICE_NAME} --region eu-central-1
      sleep 10
  # Check if there's a filesystem
      var=$(file -s ${DEVICE_NAME})
      IFS=' ' read -r -a array <<< "$var"
      if [ "$var" = "${DEVICE_NAME}: data" ]
      then
        # Make one if there's not
        mkfs -t ext4 "${DEVICE_NAME}"
        echo "mkfs -t ext4 ${DEVICE_NAME}"  >> ./Mount.log
      fi
    fi
    rm -f /tmp/checkAttach1;
    # gets volume details (with volume id VOLUME_ID ) and writes output to /tmp/checkAttach1
    aws ec2 describe-volumes --volume-id ${VOLUME_ID} --region eu-central-1 > /tmp/checkAttach
    if grep -qs "InstanceId\": \"$InstId" /tmp/checkAttach; then
        echo "Volume is avaiable now."
        echo "Volume is avaiable now." >> ./Mount.log
  # Check if volume is already mounted, if not check if it's nitro
        if grep -qs " ${MOUNT_DIR} " /proc/mounts; then
          echo "Volume is already mounted. exit"
          echo "Volume is already mounted. exit" >> ./Mount.log
          i=21
          break
        else
          echo "Volume is not mounted. check if it's a NITRO"
          echo "Volume is not mounted. check if it's a NITRO" >> ./Mount.log
          # output of lsblk command writes in /tmp/lsblk_out
          lsblk > /tmp/lsblk_out
          while read line ; do
              set -f; IFS=' '
              set -- $line
                  device=$1
                  #print variable device and checks if variable contains "nvme"
                  if echo $device | egrep -q '^nvme'
                  then
                      #get volume id of NITRO volume
                      nvm=$(nvme id-ctrl -v /dev/$device --vendor-specific -o json | grep -Po '"'"sn"'"\s*:\s*"\K([^"]*)')
                      # remove "vol" from nvm variable
                      Mynvmid="${nvm/vol/}"
                      # remove "vol-" from variable VOLUME_ID
                      Myawsid="${VOLUME_ID/vol-/}"
                      echo "$Myawsid ISNOT $Mynvmid"
                      # if  variable Myawsid is not empty
                      if [ ! -z "$Myawsid" ]
                      then
                          echo "OK: nvme $Myawsid FOUND"

                          echo "$Myawsid AND $Mynvmid"
                          if [ "$Myawsid" == "$Mynvmid" ]
                          then
                            #check if there is filesystem
                            var=$(file -s "/dev/$device")
                            IFS=' ' read -r -a array <<< "$var"
                            if [ "$var" = "/dev/$device: data" ]
                            then
                              # Make one if there's not
                              mkfs -t ext4 "/dev/$1"
                              echo "mkfs -t ext4 /dev/$1" >> ./Mount.log
                            fi
                            #mount this volume to MOUNT_DIR
                            mount /dev/$device ${MOUNT_DIR}
                            echo "mount /dev/$device ${MOUNT_DIR}" >> ./Mount.log
                            if grep -qs " ${MOUNT_DIR} " /proc/mounts; then
                                echo "Volume is mounted. - make FSTAB"
                                echo "Volume is mounted. - make FSTAB" >> ./Mount.log
                                # output of lsblk command writes in /tmp/lsblk_out
                                blkid > /tmp/blkid_out
                                while read line ; do
                                    set -f; IFS=' '
                                    set -- $line
                                        if [ "$1" == "/dev/$device:" ]
                                        then
                                            uuid=$2
                                            uuid=${uuid//\"/}
                                            fstabcheck=$(grep -n '/etc/fstab' -e $uuid)
                                            if [ -z "$fstabcheck" ]
                                            then
                                              # writes volume UUID in /etc/fstab
                                                echo "$uuid       ${MOUNT_DIR}  ext4    defaults,nofail 0 0">>/etc/fstab
                                            else
                                              echo "uuid in fstab bereits vohanden!" >> ./Mount.log
                                              echo "uuid in fstab bereits vohanden!"
                                              echo "$fstabcheck"
                                            fi
                                            i=101
                                            break
                                         else
                                              echo "ERROR: $1 is not /dev/$device"
                                              # echo "ERROR: $1 is not /dev/$device" >> ./Mount.log
                                        fi
                                done < /tmp/blkid_out
                                rm -f /tmp/blkid_out;
                            else
                                echo "ERROR: Volume is not mounted."
                                # echo "ERROR: Volume is not mounted." >> ./Mount.log
                            fi
                          fi
                      else
                      echo "ERROR: NO AWS VOLUME ID FOUND"
                      # echo "ERROR: NO AWS VOLUME ID FOUND" >> ./Mount.log
                      fi
                  else
                      echo "ERROR: NO nvme FOUND"
                      # echo "ERROR: NO nvme FOUND" >> ./Mount.log
                  fi
          done < /tmp/lsblk_out
          rm /tmp/lsblk_out -f

          if grep -qs " ${MOUNT_DIR} " /proc/mounts; then
               echo "Volume is mounted."
               echo "Volume is mounted." >> ./Mount.log
          else
              echo "Volume is not mounted. check if it's a HVM"
              echo "Volume is not mounted. check if it's a HVM" >> ./Mount.log
              # mount this volume and save in ./Mount.log
              mount ${DEVICE_NAME} ${MOUNT_DIR}
              echo "mount ${DEVICE_NAME} ${MOUNT_DIR}"
              echo "mount ${DEVICE_NAME} ${MOUNT_DIR}" >> ./Mount.log

              if grep -qs " ${MOUNT_DIR} " /proc/mounts; then
                   echo "Volume is mounted."
                   echo "Volume is mounted." >> ./Mount.log
                   # output of lsblk command writes in /tmp/lsblk_out
                     blkid > /tmp/blkid_out
                     while read line ; do
                         set -f; IFS=' '
                         set -- $line
                             if [ "$1" == "${DEVICE_NAME}:" ]
                             then
                                 uuid=$2
                                 uuid=${uuid//\"/}
                                 fstabcheck=$(grep -n '/etc/fstab' -e $uuid)
                                 if [ -z "$fstabcheck" ]
                                 then
                                   # writes volume UUID in /etc/fstab
                                     echo "$uuid       ${MOUNT_DIR}  ext4    defaults,nofail 0 0">>/etc/fstab
                                     echo "$uuid       ${MOUNT_DIR}  ext4    defaults,nofail 0 0>>/etc/fstab" >> ./Mount.log

                                 else
                                  echo "uuid in fstab bereits vohanden!"
                                  echo "uuid in fstab bereits vohanden!" >> ./Mount.log
                                  echo "$fstabcheck"
                                  i=21
                                  break
                                 fi
                             fi
                     done < /tmp/blkid_out
                     rm -f /tmp/blkid_out;

              else
                  echo "ERROR: mount ${DEVICE_NAME} ${MOUNT_DIR}"
                  echo "ERROR: ${DEVICE_NAME} ${MOUNT_DIR}" >> ./Mount.log
                  ((i++))
              fi
          fi
        fi
    else
      echo "Volume is still not available - retrey in 10 sec."
      echo "Volume is still not available - retrey in 10 sec." >> ./Mount.log
      sleep 10
      ((i++))
    fi
  done
fi
