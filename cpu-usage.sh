#!/bin/bash

declare -a HostArray=("gateway" "puchkin" "deepone" "deeptwo" "deepthree" "curie" "lovelace" "hopper" "hamilton" "mon01" )

echo -n Username: 
read username
echo
echo -n Password: 
read -s password
echo


for host in ${HostArray[@]}; do
        sshpass -p$password ssh -q $username@$host exit
        if [ $? == 0 ]
        then
                echo $host
                sshpass -p$password ssh $username@$host python3 -c '"import psutil;print(psutil.cpu_percent(interval=1, percpu=True))"'
        fi
done
