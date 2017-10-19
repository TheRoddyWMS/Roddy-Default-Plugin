#!/bin/bash

set -e
set -o pipefail

exec 1>&2

if [[ ${debugWrapInScript-false} == true ]]; then
    set -xv
elif [[ ${debugWrapInScript-false} == false ]]; then
    set +xv
else
    echo "Illegal value for debugWrapInScript: '$debugWrapInScript'. Should be {'true', 'false', ''}"
    exit 200
fi

# This script wraps in another script.
# The configuration file is sourced and has to be sourced again in the wrapped script.
# A job error entry is created in the results list along with a timestamp
#   i.e. 1237474.tbi-pbs1,START,928130918393
# This status is ignored if the script is currently planned or running
# When the job finished an entry with the job scripts exit code is created with a timestamp
#
# Cluster options (like i.e. PBS ) have to be parsed and set before job submission!
# They will be ignored after the script is wrapped.


## From http://unix.stackexchange.com/questions/26676/how-to-check-if-a-shell-is-login-interactive-batch
shellIsInteractive () {
    case $- in
        *i*) echo "true";;
        *)   echo "false";;
    esac
}
export -f shellIsInteractive


## funname () ( set +exv; ...; ) may be better to get rid of too much output (mind the (...) subshell) but the exit won't work anymore.
## Maybe set -E + trap "bla" ERR would work? http://fvue.nl/wiki/Bash:_Error_handling#Exit_on_error
printStackTrace () {
    frameNumber=0
    while caller $frameNumber ;do
      ((frameNumber++))
    done
}
export -f printStackTrace


errout () {
    local exitCode="$1"
    local message="$2"
    env printf "Error(%d): %s\n" "$exitCode" "$message" >> /dev/stderr
}
export -f errout


## This is to effectively debug on the command line. The exit is only called, in non-interactive sessions.
## You can either put 'exitIfNonInteractive $code; return $?' at the end of functions, or you put
## 'exitHere $code || return $?' in the middle of functions to end the control flow in the function and
## return to the calling function.
exitIfNonInteractive () {
    local exitValue="$1"
    if [[ $(shellIsInteractive) == false ]]; then
      exit "$exitValue"
    else
      echo "In a non-interactive session, I would now do 'exit $exitValue'" >> /dev/stderr
      return "$exitValue"
    fi
}
export -f exitIfNonInteractive

## throw [code [msg]]
## Write message (Unspecified error) to STDERR and exit with code (default 1)
throw () {
  local lastCommandsExitCode=$?
  local exitCode="${1-$UNSPECIFIED_ERROR_CODE}"
  local msg="${2-$UNSPECIFIED_ERROR_MSG}"
  if [[ $lastCommandsExitCode -ne 0 ]]; then
    msg="$msg (last exit code: $lastCommandsExitCode)"
  fi
  errout "$exitCode" "$msg"
  printStackTrace
  exitIfNonInteractive "$exitCode" || return $?
}
export -f throw

# Used to wait for a file expected to appear within the next moments. This is necessary, because in a network filesystems there may be latencies
# for synchronizing the filesystem between nodes.
waitForFile() {
    local file="${1:?No file to wait for}"
    local waitCount=0
    while [[ ${waitCount} -lt 3 && ! (-r "$file") ]]; do sleep 5; waitCount=$((waitCount + 1)); echo $waitCount; done
    if [[ ! -r "$file" ]]; then
        echo "The file '$file' does not exist or is not readable."
        exit 200
    else
        return 0
    fi
}

# Dump all file paths appearing as variable values in the environment. In particular this dumps the dereferenced symlinks.
dumpPaths() {
    local message="${1:?No log message given}"
    echo "$message"
    # To reduce the debugging output of this function the xtrace and verbose options are temporarily turned off.
    local DUMP_PATHS___SHELL_OPTIONS
    DUMP_PATHS___SHELL_OPTIONS=$(set +o)
    set +xv
    while IFS='=' read -r -d '' n v; do [[ -r $v ]] && echo "$v -> "$(readlink -f "$v"); done < <(env -0)
    if [[ ${debugWrapInScript-false} == true ]]; then set -xv; fi
    eval "$DUMP_PATHS___SHELL_OPTIONS"
    echo ""
}

# Given a tool name "x", first prefix all capitals by '_', capitalize the full name, and finally prefix the modified name by "TOOL_".
# For instance: gcBiasCorrection => TOOL_GC_BIAS_CORRECTION.
createToolVariableName() {
    local varName="${1:?No variable name given}"
    local _tmp
    tmp=$(echo "$varName" | perl -ne 's/([A-Z])/_$1/g; print uc($_)')
    echo "TOOL_$tmp"
}

# Bash < 4.2 portability version of `declare -xg`.
declare_xg() {
    local varName="${1:?No variable name given}"
    local value="${2:-}"
    eval "export $varName=\"$value\""
}

# Given a variable name, if the name starts with \${, assume it represents a tool variable reference, e.g. ${TOOL_GC_BIAS_CORRECTION}, and return the
# path this reference points to. Otherwise, assume the name refers to a tool name. Then determine the tool variable name (TOOL_...) and get the path
# referenced. This make it possible to refer to an environment script as a tool either using the ${TOOL_...} form or the raw tool name. For instance:
#
# workflowEnvironmentScript=${TOOL_GC_BIAS_CORRECTION} => $TOOL_GC_BIAS_CORRECTION
# workflowEnvironmentScript=gcBiasCorrections => $TOOL_GC_BIAS_CORRECTION
getEnvironmentScriptPath() {
    local varName="${1:?No variable name given}"
    if (echo "${!varName}" | grep -P '^\${'); then
        local scriptPath="${!varName}"
    else
        local tmp
        tmp=$(createToolVariableName "${!varName}")
        local transformedName="$tmp"
        local scriptPath="${!transformedName}"
    fi
    if [[ -z "${scriptPath:-}" ]]; then
        echo "Requested environment script variable '$varName' does not point to a value"
        exit 200
    fi
    echo "$scriptPath"
}

warnEnvironmentScriptOverride() {
    if [[ -n "${ENVIRONMENT_SCRIPT:-}" ]]; then
        echo "ENVIRONMENT_SCRIPT variable is set externally (e.g. in the XML) to '$ENVIRONMENT_SCRIPT'. It will be reset."
    fi
}

# Given the name of an environment script variable, such as "workflowEnvironmentScript" or "gcBiasCorrectionEnvironmentScript", as usually declared
# in the XML, declare the ENVIRONMENT_SCRIPT variable.
declareEnvironmentScript() {
    local envScriptVar="${1:-No environment script variable name given}"
	warnEnvironmentScriptOverride
	local tmp
	tmp=$(getEnvironmentScriptPath "$envScriptVar")
    declare_xg ENVIRONMENT_SCRIPT "$tmp"
}

# Basic modules / environment support
# Load the environment script (source), if it is defined. If the file is defined but the file not accessible exit with
# code 200. Additionally, expose the used environment script path as ENVIRONMENT_SCRIPT variable to the wrapped script.
runEnvironmentSetupScript() {
    local envScriptVar="${TOOL_ID}EnvironmentScript"
    if [[ -n "${!envScriptVar:-}" ]]; then
        declareEnvironmentScript "$envScriptVar"
    elif [[ -n "${workflowEnvironmentScript:-}" ]]; then
        declareEnvironmentScript "workflowEnvironmentScript"
    fi

    if [[ -n "${ENVIRONMENT_SCRIPT:-}" ]]; then
        if [[ ! -f "$ENVIRONMENT_SCRIPT" ]]; then
            echo "ERROR: You defined an environment loader script for the workflow but the script is not available: '$ENVIRONMENT_SCRIPT'"
            exit 200
        fi
        echo "Sourcing environment setup script from '$ENVIRONMENT_SCRIPT'"
        source "$ENVIRONMENT_SCRIPT" || throw 200 "Error sourcing $ENVIRONMENT_SCRIPT"
    fi
}

# Set the "RODDY_SCRATCH" variable and directory from the predefined "RODDY_SCRATCH" variable or the "defaultScratchDir" variable.
# Die if the resulting directory is not accessible (executable).
setupRoddyScratch() {
  # Default to the data folder on the node
  defaultScratchDir=${defaultScratchDir-/data/roddyScratch}
  [[ ${RODDY_SCRATCH-x} == "x" ]] && export RODDY_SCRATCH=${defaultScratchDir}/${RODDY_JOBID}
  [[ ! -d ${RODDY_SCRATCH} ]] && mkdir -p ${RODDY_SCRATCH}

  if [[ ! -x "$RODDY_SCRATCH" ]]; then
    throw 200 "Cannot access RODDY_SCRATCH=$RODDY_SCRATCH"
  else
    echo "RODDY_SCRATCH is set to ${RODDY_SCRATCH}"
  fi
}
###### Main ############################################################################################################

[[ ${CONFIG_FILE-false} == false ]] && echo "The parameter CONFIG_FILE is not set but is mandatory!" && exit 200
[[ ${PARAMETER_FILE-false} == false ]] && echo "The parameter PARAMETER_FILE is not set but is mandatory!" && exit 200

# Store the environment, store file locations in the env
extendedLogsDir=$(dirname "$CONFIG_FILE")/extendedLogs
mkdir -p ${extendedLogsDir}
extendedLogFile=${extendedLogsDir}/$(basename "$PARAMETER_FILE" .parameters)

dumpPaths "Files in environment before source configs" >> ${extendedLogFile}
env >> ${extendedLogFile}

## First source the CONFIG_FILE (runtimeConfig.sh) with all the global variables
waitForFile "$CONFIG_FILE"
source ${CONFIG_FILE} || throw 200 "Error sourcing $CONFIG_FILE"

if [[ ${outputFileGroup-false} != false && ${newGrpIsCalled-false} == false ]]; then
  export newGrpIsCalled=true
  export LD_LIB_PATH=$LD_LIBRARY_PATH
  # OK so something to note for you. newgrp has an undocumented feature (at least in the manpages)
  # and resets the LD_LIBRARY_PATH to "" if you do -c. -l would work, but is not feasible, as you
  # cannot call a script with it. Also I do not know whether it is possible to use it in a non-
  # interactive session (like qsub). So we just export the variable and import it later on, if it
  # was set earlier.
  # Funny things can happen... instead of newgrp we now use sg.
  # newgrp is part of several packages and behaves differently
  sg $outputFileGroup -c "/bin/bash $0"
  exit $?

else

  # Set LD_LIBRARY_PATH to LD_LIB_PATH, if the script was called recursively.
  [[ ${LD_LIB_PATH-false} != false ]] && export LD_LIBRARY_PATH=$LD_LIB_PATH

  ## Then source the PARAMETER_FILE with all the job-specific settings.
  waitForFile "$PARAMETER_FILE"
  source ${PARAMETER_FILE} || throw 200 "Error sourcing $PARAMETER_FILE"

  dumpPaths "Files in environment after source configs" >> ${extendedLogFile}
  env >> ${extendedLogFile}

  runEnvironmentSetupScript

  dumpPaths "Files in environment after sourcing the environment script" >> ${extendedLogFile}
  env >> ${extendedLogFile}

  export RODDY_JOBID=${RODDY_JOBID-$$}
  echo "RODDY_JOBID is set to ${RODDY_JOBID}"

  # Replace #{RODDY_JOBID} in passed variables.
  while read line; do
    echo $line
    _temp=$RODDY_JOBID
    export RODDY_JOBID=`echo $RODDY_JOBID | cut -d "." -f 1`
    line=${line//-x/};
    eval ${line//#/\$};
    export RODDY_JOBID=$_temp
  done <<< `export | grep "#{"`

  setupRoddyScratch

  # Check
  _lock="$jobStateLogFile~"

  # Select the proper lock command. lockfile-create is not tested though.
  lockCommand="lockfile -s 1 -r 50"
  unlockCommand="rm -f"

  useLockfile=true
  [[ -z `which lockfile` ]] && useLockfile=false
  [[ ${useLockfile} == false ]] && lockCommand=lockfile-create && unlockCommand=lockfile-remove && echo "Set lockfile commands to lockfile-create and lockfile-remove"

  startCode=STARTED

  # Check if the jobs parent jobs are stored and passed as a parameter. If so Roddy checks the job jobState logfile
  # if at least one of the parent jobs exited with a value different to 0.

  # Now check all lines in the file
  # OMG: Bash sucks sooo much: https://stackoverflow.com/questions/7577052/bash-empty-array-expansion-with-set-u
  if [[ -n "${RODDY_PARENT_JOBS[@]:-}" ]]; then
      for parentJob in "${RODDY_PARENT_JOBS[@]}"; do
         [[ ${exitCode-} == 250 ]] && continue;
         result=`cat ${jobStateLogFile} | grep -a "^${parentJob}:" | tail -n 1 | cut -d ":" -f 2`
         [[ $result -ne 0 ]] && echo "At least one of this parents jobs exited with an error code. This job will not run." && startCode="ABORTED"
      done
  fi

  # Check the wrapped script for existence
  [[ ${WRAPPED_SCRIPT-false} == false || ! -f ${WRAPPED_SCRIPT} ]] && startCode=ABORTED && echo "The wrapped script is not defined or not existing."

  ${lockCommand} $_lock;
  echo "${RODDY_JOBID}:${startCode}:"`date +"%s"`":${TOOL_ID}" >> ${jobStateLogFile};
  ${unlockCommand} $_lock
  [[ ${startCode} == "ABORTED" ]] && echo "Exiting because a former job died." && exit 250
  # Sleep a second before and after executing the wrapped script. Allow the system to get different timestamps.
  sleep 2

  export WRAPPED_SCRIPT=${WRAPPED_SCRIPT} # Export script so it can identify itself

  # Create directories
  mkdir -p ${DIR_TEMP} 2 > /dev/null

  echo "Calling script ${WRAPPED_SCRIPT}"
  jobProfilerBinary=${JOB_PROFILER_BINARY-}
  [[ ${enableJobProfiling-false} == false ]] && jobProfilerBinary=""

  myGroup=`groups  | cut -d " " -f 1`
  outputFileGroup=${outputFileGroup-$myGroup}

  exitCode=0
  echo "######################################################### Starting wrapped script ###########################################################"
  $jobProfilerBinary bash -x ${WRAPPED_SCRIPT} 1>> /dev/stdout 2>> /dev/stderr || exitCode=$?
  echo "######################################################### Wrapped script ended ##############################################################"
  echo "Exited script ${WRAPPED_SCRIPT} with value ${exitCode}"

  # If the tool supports auto checkpoints and the exit code is 0, then go on and create it.
  [[ ${AUTOCHECKPOINT-""} && exitCode == 0 ]] && touch ${AUTOCHECKPOINT}

  sleep 2

  ${lockCommand} $_lock;
  echo "${RODDY_JOBID}:${exitCode}:"`date +"%s"`":${TOOL_ID}" >> ${jobStateLogFile};
  ${unlockCommand} $_lock

  # Set this in your command factory class, when roddy should clean up the dir for you.
  [[ ${RODDY_AUTOCLEANUP_SCRATCH-false} == "true" ]] && rm -rf ${RODDY_SCRATCH} && echo "Auto cleaned up RODDY_SCRATCH"

  [[ ${exitCode} -eq 0 ]] && exit 0

  [[ ${exitCode} -eq 100 ]] && echo "Finished script with 99 for compatibility reasons with Sun Grid Engine. 100 is reserved for SGE usage." && exit 99
  exit $exitCode

fi
