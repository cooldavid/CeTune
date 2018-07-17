#!/bin/bash

#1. generate a vm xml
function set_vm_xml {
    local vmxml=$1
    local vclient_name=$2
    local cpuset=$3
    local img_path=$4
    local mac_address=$5

    echo '<domain type="kvm">' > $vmxml
    echo '    <name>'${vclient_name}'</name>' >> $vmxml
    echo '    <memory>524288</memory>' >> $vmxml
    echo '    <vcpu>1</vcpu>' >> $vmxml
    echo '    <cputune>' >> $vmxml
    echo '        <vcpupin vcpu="0" cpuset="'${cpuset}'"/>' >> $vmxml
    echo '    </cputune>' >> $vmxml
    echo '    <os>' >> $vmxml
    echo '        <type>hvm</type>' >> $vmxml
    echo '        <boot dev="hd"/>' >> $vmxml
    echo '    </os>' >> $vmxml
    echo '    <features>' >> $vmxml
    echo '        <acpi/>' >> $vmxml
    echo '    </features>' >> $vmxml
    echo '    <clock offset="utc">' >> $vmxml
    echo '        <timer name="pit" tickpolicy="delay"/>' >> $vmxml
    echo '        <timer name="rtc" tickpolicy="catchup"/>' >> $vmxml
    echo '    </clock>' >> $vmxml
    echo '    <cpu mode="host-model" match="exact"/>' >> $vmxml
    echo '    <devices>' >> $vmxml
    echo '        <disk type="file" device="disk">' >> $vmxml
    echo '            <driver name="qemu" type="raw" cache="none"/>' >> $vmxml
    echo '            <source file="'${img_path}'" />' >> $vmxml
    echo '            <target bus="virtio" dev="vda"/>' >> $vmxml
    echo '        </disk>' >> $vmxml
    echo '        <interface type="bridge" >' >> $vmxml
    echo '            <source bridge ="br0"/>' >> $vmxml
    echo '            <mac address ="'$mac_address'"/>' >> $vmxml
    echo '        </interface>' >> $vmxml
    echo '        <serial type="pty"/>' >> $vmxml
    echo '        <input type="tablet" bus="usb"/>' >> $vmxml
    echo '        <graphics type="vnc" autoport="yes" keymap="en-us" listen="0.0.0.0"/>' >> $vmxml
    echo '    </devices>' >> $vmxml
    echo '</domain>' >> $vmxml
}


function usage_exit {
    echo -e "usage:\n\t $0 cpuset_start"
    exit
}

function copy_and_patch_image {
    local client=$1
    local vclient=$2
    local img_path=$3
    local ip=$4
    local mac_address=$5
    local img_path_tmp="${img_path}.mnt"

    cat >${vclient}.cmdlist.sh <<EOL
#!/bin/bash

echo "copy $vclient img"
cp ${img_path_dir}/vclient.tmp.img $img_path || exit -1
echo "edit $vclient img"
mkdir ${img_path_tmp} || (echo "Failed to mkdir on ${client}: ${img_path_tmp}" && exit -1)
mount -o loop,offset=1048576 ${img_path} ${img_path_tmp} || (echo "Failed to mount on ${client}: mount -o loop,offset=1048576 ${img_path} ${img_path_tmp}" && exit -1)

cp ${img_path_dir}/ssh.authorized_keys ${img_path_tmp}/root/.ssh/authorized_keys

patch_vm_sh=${img_path_tmp}/root/patch_vm_sh
echo "#!/bin/bash

      rm -f /etc/ssh/ssh_host_*
      ssh-keygen -q -t dsa -N '' -f /etc/ssh/ssh_host_dsa_key
      ssh-keygen -q -t ecdsa -N '' -f /etc/ssh/ssh_host_ecdsa_key
      ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/ssh_host_ed25519sa_key
      ssh-keygen -q -t rsa -N '' -f /etc/ssh/ssh_host_rsa_key
      sed -i 's/^PermitRootLogin .\\+\$/PermitRootLogin yes/g' /etc/ssh/sshd_config

      chown root:root /root/.ssh/authorized_keys
      chmod 600 /root/.ssh/authorized_keys
      systemctl enable ssh >& /dev/null

      echo ${vclient} > /etc/hostname

      rm -f /etc/network/interfaces.d/*
      echo 'SUBSYSTEM==\"net\", ACTION==\"add\", DRIVERS==\"?*\", ATTR{address}==\"${mac_address}\", NAME=\"eth0\"' > /etc/udev/rules.d/70-persistent-net.rules

      echo \"auto eth0
             iface eth0 inet static
             address ${ip}
             netmask ${vclient_ip_mask}
             gateway ${vclient_ip_gw}\" > /etc/network/interfaces.d/50-eth0-fixed.cfg

      mkdir -p ${tmp_dir}

      " > \${patch_vm_sh}
chmod +x \${patch_vm_sh}
chroot ${img_path_tmp} /root/patch_vm_sh
rm -f \${patch_vm_sh}

umount ${img_path_tmp} || (echo "Failed to umount on ${client}: ${img_path_tmp}" && exit -1)
rmdir ${img_path_tmp} || (echo "Failed to rmdir on ${client}: ${img_path_tmp}" && exit -1)
echo "Finished $vclient img"

EOL

    scp ${vclient}.cmdlist.sh ${client}:${img_path_dir}/
    rm -f ${vclient}.cmdlist.sh
    ssh ${client} "bash ${img_path_dir}/${vclient}.cmdlist.sh && rm ${img_path_dir}/${vclient}.cmdlist.sh"
}

function main {
    mac_address_fix=1
    mac_address_prefix="52:54:00:b2:3c:"
    vm_num=0

    mkdir -p vmxml

    if [ ! -f vclient.tmp.img ]; then
        echo " Download the vclient.tmp.img from $vm_image_locate_path "
        scp "$vm_image_locate_path" vclient.tmp.img
        if [ "$?" != "0" ]; then
            echo "Downloading failed"
            exit
        fi
    fi
    vclients=`echo ${list_vclient} | sed 's/,/ /g'`
    clients=(`echo ${list_client} | sed 's/,/ /g'`)
    clientnr=${#clients[@]}
    clientidx=0

    for client in ${clients[@]}; do
        ssh ${client} mkdir -p ${dest_dir} &
        ssh ${client} "mkdir -p ${img_path_dir}/vmxml" &
        scp vclient.tmp.img ${client}:${img_path_dir}/ &
        ssh ${client} "if [ ! -f ~/.ssh/id_rsa.pub ]; then ssh-keygen -t rsa -b 8192 -N '' -f ~/.ssh/id_rsa; fi" &
    done
    wait

    rm -f ssh.authorized_keys
    for client in ${clients[@]}; do
        ssh ${client} "cat ~/.ssh/id_rsa.pub" >> ssh.authorized_keys
    done
    chmod 644 ssh.authorized_keys

    for client in ${clients[@]}; do
        scp ssh.authorized_keys ${client}:${img_path_dir}/ &
    done
    wait

    client=${clients[$clientidx]}
    for vclient in $vclients
    do
        echo "create $vclient xml on ${client}"
    #====== create vm xml ======
        vmxml=$vclient".xml"
        vmname=$vclient
        img_path=$img_path_dir"/"$vclient".img"
        mac_address=$mac_address_prefix$(printf "%02x" $mac_address_fix)
        set_vm_xml "vmxml/${vmxml}" $vmname $cpuset $img_path $mac_address
        scp "vmxml/${vmxml}" "${client}:${img_path_dir}/vmxml/" || exit -1
        rm "vmxml/${vmxml}"

    #===== edit vm img ======
        ip=$vclient_ip_prefix"."$vclient_ip_start
        echo "copy tmp.img as ${vclient} to ${client}"
        copy_and_patch_image $client $vclient $img_path $ip $mac_address &
        vclient_ip_start=$(( $vclient_ip_start + 1 ))

    #===== edit /etc/hosts ======
        ssh ${client} "if [[ \$(grep ${vclient} /etc/hosts) == \"\" ]]; then echo \"${ip} ${vclient}\" >> /etc/hosts; fi"

    #===== advance to next vclient ======
        cpuset=$(( $cpuset + 1 ))
        vm_num=$(( vm_num + 1 ))
        if [ "$vm_num" = "$vm_num_per_client" ];then
            vm_num=0
            cpuset=$cpuset_start
            let clientidx=clientidx+1
            if (( $clientidx >= $clientnr )); then
                clientidx=0
            fi
	    client=${clients[$clientidx]}
        fi
        mac_address_fix=$(( $mac_address_fix + 1 ))
        if [ "$mac_address_fix" = "256" ];then
            mac_address_prefix="52:54:00:b2:3b:"
            mac_address_fix=1
        fi
    done
    wait
}

if [ "$#" != "1" ]; then
    usage_exit
fi

cpuset=$1
cpuset_start=$cpuset
. ../conf/common.sh
get_conf

has_error=0
if [[ ! "$vclient_ip_prefix" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] ||
    (( ${BASH_REMATCH[1]} >= 256 )) ||
    (( ${BASH_REMATCH[2]} >= 256 )) ||
    (( ${BASH_REMATCH[3]} >= 256 )); then
    echo "Please correctly set vclient_ip_prefix in all.conf. ex: 10.1.1"
    has_error=1
fi
if [[ ! "$vclient_ip_start" =~ ^([0-9]{1,3})$ ]] || (( ${BASH_REMATCH[1]} >= 256 )); then
    echo "Please correctly set vclient_ip_start in all.conf. ex: 10"
    has_error=1
fi
if [[ ! "$vclient_ip_mask" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] ||
    (( ${BASH_REMATCH[1]} >= 256 )) ||
    (( ${BASH_REMATCH[2]} >= 256 )) ||
    (( ${BASH_REMATCH[3]} >= 256 )) ||
    (( ${BASH_REMATCH[4]} >= 256 )); then
    echo "Please correctly set vclient_ip_mask in all.conf. ex: 255.255.255.0"
    has_error=1
fi
if [[ ! "$vclient_ip_gw" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] ||
    (( ${BASH_REMATCH[1]} >= 256 )) ||
    (( ${BASH_REMATCH[2]} >= 256 )) ||
    (( ${BASH_REMATCH[3]} >= 256 )) ||
    (( ${BASH_REMATCH[4]} >= 256 )); then
    echo "Please correctly set vclient_ip_gw in all.conf. ex: 10.1.1.254"
    has_error=1
fi
if (( $has_error == 1)); then
    exit
fi

main
