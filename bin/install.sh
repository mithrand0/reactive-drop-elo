#!/bin/bash
set -e

# compile
export DEBUG=-all 
cd /root/reactivedrop/reactivedrop/addons/sourcemod/scripting/

# plugins
for plugin in $(ls rd_*.sp); do
    echo "processing: ${plugin}.."
    base=$(echo "${plugin}" | cut -d "." -f 1)
    echo "+ compiling: ${base}.."
    wine spcomp.exe "${plugin}"
    mv "${base}.smx" ../plugins/
done

# remove stuff we don't want there
cd ../
rm -rf scripting

# remove temp folder
rm -rf /tmp/*
