#
# Copyright (c) 2020 German Cancer Research Center (DKFZ).
#
# Distributed under the MIT License (license terms are at https://github.com/DKFZ-ODCF/AlignmentAndQCWorkflows).
#

DEFAULTPLUGIN_LIB___SHELL_OPTIONS=$(set +o)
set +o verbose
set +o xtrace

setCompressionToolsBasedOnFileCompression() {
    local testFile="${1:?No file to determine compression}"
    if [[ ! -r "$testFile" ]]; then
        echo "File '$testFile' is not accessible. Cannot determine compression" >> /dev/stderr
        exit 1
    fi
    local compression=`file -bL "$testFile" | cut -d ' ' -f 1`
    if [[ $compression = "setgid" ]]  # "setgid gzip compressed data": sticky bit is set for the file
    then
        compression=`file -bL "$testFile" | cut -d ' ' -f 2`
    fi
    if [[ "$compression" == "gzip" ]]
    then
        echo "gzip-compression"
        declare -g UNZIPTOOL="gunzip"
        declare -g UNZIPTOOL_OPTIONS=" -c"
        declare -g ZIPTOOL="gzip"
        declare -g ZIPTOOL_OPTIONS=" -c"
    elif [[ "$compression" == "bzip2" ]]
    then
        echo "bzip2-compression"
        declare -g UNZIPTOOL="bunzip2"
        declare -g UNZIPTOOL_OPTIONS=" -c -k"
        declare -g ZIPTOOL="bzip2"
        declare -g ZIPTOOL_OPTIONS=" -c -k"
    elif [[ "$compression" == "ASCII" ]]
    then
        echo "ASCII"
        declare -g UNZIPTOOL="cat"
        declare -g UNZIPTOOL_OPTIONS=""
        declare -g ZIPTOOL="head"
        declare -g ZIPTOOL_OPTIONS=" -n E"
    else
      echo "Unknown compression $compression; skipping $1"
    fi
}


eval "$DEFAULTPLUGIN_LIB___SHELL_OPTIONS"
