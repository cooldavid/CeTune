#!/bin/bash
. ../conf/common.sh
get_conf

for client in `echo ${list_client} | sed 's/,/ /g'`; do
    ssh ${client} "virsh capabilities; for vmxml in ${img_path_dir}/vmxml/*.xml; do virsh create \${vmxml}; done" &
done
wait
