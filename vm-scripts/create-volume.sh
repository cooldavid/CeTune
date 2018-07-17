#!/bin/bash
. ../conf/common.sh
get_conf

function create_vdb_xml {
    mkdir -p ./vdbs
    index=0
    auth=$1
    nodes=`echo ${list_vclient} | sed 's/,/ /g'`
    for vm in $nodes
    do
        index=$(( $index + 1 ))
        volume=`rbd -p $rbd_pool ls | sed -n "${index}p"`
        echo "<disk type='network' device='disk'>" > ./vdbs/$vm.xml
        echo "    <driver name='qemu' type='raw' cache='none'/>" >> ./vdbs/$vm.xml
	if [ "$auth" != "none" ] ;then
            echo "    <auth username='admin'>" >> ./vdbs/$vm.xml
            echo "        <secret type='ceph' uuid='"$auth"'/>" >> ./vdbs/$vm.xml
            echo "    </auth>" >> ./vdbs/$vm.xml
        fi
	echo -n "    <source protocol='rbd' name='$rbd_pool/" >> ./vdbs/$vm.xml
        echo "$volume' />">> ./vdbs/$vm.xml
        echo "    <target dev='vdb' bus='virtio'/>" >> ./vdbs/$vm.xml
        echo "    <serial>009ad738-1a2e-4d9c-bf22-1993c8c67ade</serial>" >> ./vdbs/$vm.xml
        echo "    <address type='pci' domain='0x0000' bus='0x00' slot='0x06' function='0x0'/>" >> ./vdbs/$vm.xml
        echo "</disk>" >> ./vdbs/$vm.xml
    done
}

function create_rbd_volume {
	if [ "${rbd_volume_count}" == '' ];then
    	nodes_num=`echo ${list_vclient} | sed 's/,/\n/g' | wc -l`
	else
		nodes_num=${rbd_volume_count}
	fi
    volume_num=`rbd -p $rbd_pool ls | wc -l`
    need_to_create=0
    if [ $nodes_num -gt $volume_num ]; then
        need_to_create=$(( $nodes_num - $volume_num ))
    fi
    if [ $need_to_create -eq 0 ]; then
		echo "Do not need to create new rbd volume, your current rbd volume number is enough."
    else
        for i in `seq 1 $need_to_create`
        do
	    volume="volume-"`uuidgen`
            rbd create -p $rbd_pool --size=${volume_size} --image-format=2 --image-feature=layering $volume
        done
    fi
}

function rm_rbd_volume {
    rbd -p $rbd_pool ls | while read volume
    do
        rbd -p $rbd_pool rm $volume
    done
}

function get_secret {
    ceph_cluster_uuid=`ceph fsid`
    echo $ceph_cluster_uuid
}

function create_secret {
    ceph auth get-or-create client.admin mon 'allow *' osd 'allow *' -o /etc/ceph/ceph.client.admin.keyring
    keyring=`cat /etc/ceph/ceph.client.admin.keyring | grep key | awk '{print $3}'`
    ceph_cluster_uuid=`ceph fsid`
    echo "<secret ephemeral='no' private='no'>" > secret.xml
    echo "   <uuid>$ceph_cluster_uuid</uuid>" >> secret.xml
    echo "   <usage type='ceph'>" >> secret.xml
    echo "       <name>client.admin secret</name>" >> secret.xml
    echo "   </usage>" >> secret.xml
    echo "</secret>" >> secret.xml
    virsh secret-define --file secret.xml
    virsh secret-set-value $ceph_cluster_uuid $keyring
}

#=================  main  ===================

function usage_exit {
    echo -e "usage:\n\t $0 {-h|create_rbd|remove_rbd|create_disk_xml}"
    exit
}

case $1 in
    -h | --help)
        usage_exit
	;;
    create_rbd)
        create_rbd_volume
	;;        
    remove_rbd)
        rm_rbd_volume
	;;        
    create_disk_xml) 
        echo "If you use CephX, pls make sure the secret.xml locates in vm-scripts"
        select opt in "secret.xml exists, continue with cephx" "help to generate secret.xml first than create volume" "continue with none auth"
        do
            case "$opt" in
                "secret.xml exists, continue with cephx")
                    auth=`get_secret`
        	    create_vdb_xml $auth
        	    break
        	    ;;
        	"help to generate secret.xml first than create volume")
        	    create_secret
                    auth=`get_secret`
        	    create_vdb_xml $auth
        	    break
        	    ;;
        	"continue with none auth")
        	    create_vdb_xml none
        	    break
        	    ;;
        	*) echo invalid option;;
            esac
        done

        cliets=(`echo ${list_client} | sed 's/,/ /g'`)
        clientnr=${#cliets[@]}
        clientidx=0
        client=${cliets[$clientidx]}
        ssh ${client} "mkdir -p ${img_path_dir}/vdbs"

        vm_num=0
        vclients=`echo ${list_vclient} | sed 's/,/ /g'`
        for vclient in $vclients; do
            scp vdbs/${vclient}.xml ${client}:${img_path_dir}/vdbs/ &
            sleep 0.1
            let vm_num=vm_num+1
            if [ "$vm_num" = "$vm_num_per_client" ];then
                vm_num=0
                let clientidx=clientidx+1
                if (( $clientidx >= $clientnr )); then
                    clientidx=0
                fi
                client=${cliets[$clientidx]}
                ssh ${client} "mkdir -p ${img_path_dir}/vdbs"
            fi
        done
        wait

	;;
    *)
        usage_exit
	;;
esac
