#!/bin/bash
. ../conf/common.sh
get_conf

for client in `echo ${list_client} | sed 's/,/ /g'`; do
    ssh ${client} "for vm in \`virsh list | grep vclient | awk '{print \$2;}'\`; do virsh detach-device \$vm ${img_path_dir}/vdbs/\${vm}.xml; done" &
done
wait

