#!/bin/bash
. ../conf/common.sh
get_conf

for client in `echo ${list_client} | sed 's/,/ /g'`; do
    if [[ "$1" == "hard" ]]; then
        cmd="virsh destroy \${vm}"
    else
        cmd="ssh \${vm} poweroff"
    fi
    ssh ${client} "for vm in \`virsh list | grep vclient | awk '{print \$2;}'\`; do ${cmd}; done"
done
wait

