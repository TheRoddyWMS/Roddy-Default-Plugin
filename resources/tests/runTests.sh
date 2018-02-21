#!/usr/bin/env bash

currentDir=$(dirname $(readlink -f "$0"))
runner=${SHUNIT2:?No SHUNIT2 variable. Point it to the shunit2 of https://github.com/kward/shunit2.git.}

export SRC_ROOT=$(readlink -f $currentDir/../)

for t in $(find $currentDir/ -mindepth 2 -type f -name "*.sh"); do
    2>&1 echo "Running tests in '$t' ..."
    bash $t
done


