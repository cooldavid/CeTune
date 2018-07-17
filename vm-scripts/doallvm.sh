#!/bin/bash
. ../conf/common.sh
get_conf

for vclient in `echo ${list_vclient} | sed 's/,/ /g'`; do
    ssh ${vclient} $@ &
done
wait
