#!/bin/bash

exec >> /var/log/autoSnapshot.log 2>&1
echo "Script ran at $(date)"

##########################################################

# Project: Openstack Automatic Snapshots
# Author : houtknots
# Website: https://houtknots.com/
# Github : https://github.com/houtknots

##########################################################

# Specify where you Openstack RC File - instructions on where to find your OpenRC file: https://www.transip.eu/knowledgebase/7372-where-are-openstack-api-credentials/
# You can also specify the RC file location like: `./script.sh <rcfile location>`
rcFile="${1:-/usr/local/rcfile.sh}"

# How many instance snapshots (images) with tag autoSnapshot to keep
KEEP_INSTANCE_SNAPSHOTS=1

# How many volume snapshots with name starting with "autoSnapshot" to keep
KEEP_VOLUME_SNAPSHOTS=1

###############################
# DO NOT EDIT BELOW THIS LINE #
###############################

# Set Variables
date=$(date +"%Y-%m-%d")
dateForName=$(date +"%Y-%m-%d-%T")

# Arrays to remember which snapshots we create in this run
newInstanceSnapshots=()
newVolumeSnapshots=()

# If RC file exists load the rcfile, otherwise announce it does not exist and exit script with exit code 1
if [ -f "$rcFile" ]; then
  source "$rcFile"
else
  echo "Make sure you specify the Openstack RC-FILE - instructions on where to find your OpenRC file: https://www.transip.eu/knowledgebase/7372-where-are-openstack-api-credentials/"
  exit 1
fi

##########################
# Snapshot Creation      #
##########################
# Announce snapshot creation
printf '%*s\n' "${COLUMNS:-$(tput cols)}" '' | tr ' ' -
echo "Creating instance snapshots!"

# If an instance has the autoSnapshot metadata tag is true create snapshots!
for instance in $(openstack server list -c ID -f value); do
  # Retrieve the required info from the instance.
  properties=$(openstack server show "$instance" -c properties -f value)
  instanceName=$(openstack server show "$instance" -c name -f value)

  # Check if the autoSnapshot is set to true, if this is the case create a snapshot of that instance, otherwise skip the instance.
  if [[ $properties =~ "{'autoSnapshot': 'true'}" ]]; then
    echo "Creating snapshot of instance: ${instanceName} - ${instance}"
    snapshotID=$(openstack server image create "$instance" -c id -f value --name "autoSnapshot_${dateForName}_${instanceName}" | xargs)
    openstack image set "$snapshotID" --tag autoSnapshot

    # Remember this snapshot so we don't delete it later
    newInstanceSnapshots+=("$snapshotID")

    # If snapshotSync is set to true, disable image type so image will sync over all DC's
    if [[ $properties =~ "snapshotSync='true'" ]]; then
      openstack image unset "$snapshotID" --property image_type
    fi
  else
    echo "Skipping instance! Metadata key not set: ${instanceName} - ${instance}"
  fi
done

# Announce volume snapshot creation
printf '%*s\n' "${COLUMNS:-$(tput cols)}" '' | tr ' ' -
echo "Creating volume snapshots!"

# If an instance has the autoSnapshot metadata tag is true create snapshots!
for volume in $(openstack volume list -c ID -f value); do
  # Retrieve the required info from the volume.
  properties=$(openstack volume show "$volume" -c properties -f value | sed 's/ //g')
  volumeName=$(openstack volume show "$volume" -c name -f value)

  # Check if the autoSnapshot is set to true, if this is the case create a snapshot of that volume, otherwise skip the volume.
  if [[ $properties == *"'autoSnapshot':'true'"* ]]; then
    echo "Creating snapshot of volume: ${volumeName} - ${volume}"
    snapshotID=$(openstack volume snapshot create "$volume" -c id -f value --description "autoSnapshot_${date}_${volumeName}" | xargs)
    openstack volume snapshot set "$snapshotID" --property autoSnapshot=true --name "autoSnapshot_${date}_${volumeName}"

    # Remember this snapshot so we don't delete it later
    newVolumeSnapshots+=("$snapshotID")
  else
    echo "Skipping volume! Metadata key not set: ${volumeName} - ${volume}"
  fi
done

##########################
# Snapshot Deletion      #
##########################

# Announce snapshot deletion
printf '%*s\n' "${COLUMNS:-$(tput cols)}" '' | tr ' ' -
echo "Deleting old instance snapshots (keeping $KEEP_INSTANCE_SNAPSHOTS newest)!"

# Get all snapshot/image UUIDs that have the autoSnapshot tag
images=$(openstack image list --tag autoSnapshot -f value -c ID)

if [ -z "$images" ]; then
  echo "No instance snapshots found."
else
  snapshot_list=""

  # Build "epoch ID" list for sorting
  for image in $images; do
    created_at=$(openstack image show "$image" -f value -c created_at)
    epoch_created=$(date --date "$created_at" +'%s')
    snapshot_list="${snapshot_list}${epoch_created} ${image}\n"
  done

  # Sort by time (oldest first)
  snapshots_sorted=$(printf "$snapshot_list" | sort -n)

  # How many snapshots do we have?
  total=$(printf "%s\n" "$snapshots_sorted" | wc -l | awk '{print $1}')

  if [ "$total" -le "$KEEP_INSTANCE_SNAPSHOTS" ]; then
    echo "Have $total instance snapshots, configured to keep $KEEP_INSTANCE_SNAPSHOTS -> nothing to delete."
  else
    delete_count=$((total - KEEP_INSTANCE_SNAPSHOTS))
    echo "Have $total instance snapshots, will delete $delete_count oldest."

    # Take the oldest ones (the first delete_count lines) and delete them
    to_delete=$(printf "%s\n" "$snapshots_sorted" | head -n "$delete_count" | awk '{print $2}')

    for image in $to_delete; do
      echo "Deleting old instance snapshot: $image"
      openstack image delete "$image"
    done
  fi
fi

# Announce volume snapshot deletion
printf '%*s\n' "${COLUMNS:-$(tput cols)}" '' | tr ' ' -
echo "Deleting old volume snapshots (keeping $KEEP_VOLUME_SNAPSHOTS newest)!"

# Get all volume snapshot IDs
vsnapshots=$(openstack volume snapshot list -c ID -f value)

snapshot_list=""

# Build "epoch ID" list, but only for snapshots whose name starts with autoSnapshot
for vsnapshot in $vsnapshots; do
  vsnapshotName=$(openstack volume snapshot show "$vsnapshot" -c name -f value)
  if [[ "$vsnapshotName" == autoSnapshot* ]]; then
    created_at=$(openstack volume snapshot show "$vsnapshot" -f value -c created_at)
    epoch_created=$(date --date "$created_at" +%s)
    snapshot_list="${snapshot_list}${epoch_created} ${vsnapshot}\n"
  fi
done

if [ -z "$snapshot_list" ]; then
  echo "No autoSnapshot volume snapshots found."
else
  snapshots_sorted=$(printf "$snapshot_list" | sort -n)
  total=$(printf "%s\n" "$snapshots_sorted" | wc -l | awk '{print $1}')

  if [ "$total" -le "$KEEP_VOLUME_SNAPSHOTS" ]; then
    echo "Have $total volume snapshots, configured to keep $KEEP_VOLUME_SNAPSHOTS -> nothing to delete."
  else
    delete_count=$((total - KEEP_VOLUME_SNAPSHOTS))
    echo "Have $total autoSnapshot volume snapshots, will delete $delete_count oldest."

    to_delete=$(printf "%s\n" "$snapshots_sorted" | head -n "$delete_count" | awk '{print $2}')

    for vsnapshot in $to_delete; do
      echo "Deleting old volume snapshot: $vsnapshot"
      openstack volume snapshot delete "$vsnapshot"
    done
  fi
fi

# Announce the script has finished and exit the script with errorcode 0
printf '%*s\n' "${COLUMNS:-$(tput cols)}" '' | tr ' ' -
echo "Finished!"
exit 0
