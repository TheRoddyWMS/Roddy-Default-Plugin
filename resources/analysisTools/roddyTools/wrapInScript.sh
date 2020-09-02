#!/usr/bin/env bash
#
# Copyright (c) 2020 German Cancer Research Center (DKFZ).
#
# Distributed under the MIT License (license terms are at https://github.com/DKFZ-ODCF/AlignmentAndQCWorkflows).
#

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

bashMajorVersion() {
    echo $BASH_VERSION | cut -f 1 -d.
}

bashMinorVersion() {
    echo $BASH_VERSION | cut -f 2 -d.
}

assertBashMinMinorVersion() {
    local major="${1:-0}"
    local minor="${2:-0}"
    if [[ $(bashMajorVersion) -lt $major || ($(bashMajorVersion) -eq $major && $(bashMinorVersion) -lt $minor) ]]; then
        echo "Need at least Bash version $major.$minor to run wrapper" >> /dev/stderr
        exit 200
    fi
}

assertBashMinMinorVersion 4 2

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

# Set the "RODDY_SCRATCH" variable and directory from the predefined "RODDY_SCRATCH" variable or the extended "scratchBaseDirectory" variable.
# Die if the resulting directory is not accessible (executable, readable and writable).
setupRoddyScratch() {
    if [[ "${RODDY_SCRATCH:-}" == "" ]]; then
        throw 200 "Undefined RODDY_SCRATCH variable."
    elif [[ ! -d ${RODDY_SCRATCH} ]]; then
        mkdir -p ${RODDY_SCRATCH}
    fi
    if [[ ! -x "$RODDY_SCRATCH" && ! -r "$RODDY_SCRATCH" && ! -w "$RODDY_SCRATCH" ]]; then
        throw 200 "Cannot access RODDY_SCRATCH=$RODDY_SCRATCH, please check its access rights"
    fi
    echo "RODDY_SCRATCH is set to ${RODDY_SCRATCH}"
}

# Source the script pointed to be the baseEnvironmentScript variable.
sourceBaseEnvironmentScript() {
    if [[ -v baseEnvironmentScript && -n "$baseEnvironmentScript" ]]; then
        if [[ ! -r "$baseEnvironmentScript" ]]; then
            throw 200 "Cannot access baseEnvironmentScript: '$baseEnvironmentScript'"
        fi
        local sourceBaseEnvironment_SHELL_OPTIONS=$(set +o)
        set +uvex    # Need to be unset because the scripts may be out of control of the person executing the workflow.
        source "$baseEnvironmentScript"
        eval "$sourceBaseEnvironment_SHELL_OPTIONS"
    fi
}

# Get list of child processes. There is no guarantee that the processes continue to exist after the call to childProcesses.
childProcesses() {
    # Note that the terminal sed in the following expression is necessary, because pstree seems to behave differently in interactive and non-
    # interactive mode. In non-interactive mode, pstree appends a '...' to every non-terminal process ID.
    declare -a pidList=( $(pstree -a -p $$ | cut -d, -f2 | cut -d" " -f1 | grep -v $$ | sed -r 's/\.*//g') )

    ## To get a clean list of subprocesses we remove the PIDs of the cut, grep, and sed commands and that of the current subshell.
    for pid in "${pidList[@]}"; do
        if [[ "$pid" != "$BASHPID" ]]; then
            if processesExist "$pid"; then
                echo "$pid"
            fi
        fi
    done
}

processesExist() {
    declare -a pids=( "$@" )
    if [[ ${#pids[@]} -eq 0 ]]; then
        throw 100 "No process IDs given"
    fi
    ps --no-header --pid "${pid[@]}" > /dev/null
}

# Check for background jobs and kill them.
killChildProcesses() {
  local KILLSIG=TERM
  declare -a childProcs=( $(childProcesses) )
  if [[ ${#childProcs[@]} -gt 0 ]]; then
    echo "Wrapped script terminated but background jobs remain. Killing them with $KILLSIG. Here is the process tree:"
    pstree -a -p $$
    # Important: There is actually no guarantee that these PIDs, although they originate from child-processes, are still valid or from the
    # same process as before. They could now be from another process from this user, or even from another user. The chance that this happens
    # may be low, because of the way Linux uses PIDs, but it is not zero. So beware.
    /usr/bin/kill -s "$KILLSIG" "${childProcs[@]}" > /dev/null 2>&1 || true
  fi
}

###### Main ############################################################################################################

[[ ${PARAMETER_FILE-false} == false ]] && echo "The parameter PARAMETER_FILE is not set but is mandatory!" && exit 200

sourceBaseEnvironmentScript

# Store the environment, store file locations in the env
extendedLogsDir=$(dirname "$PARAMETER_FILE")/extendedLogs
mkdir -p ${extendedLogsDir}
extendedLogFile=${extendedLogsDir}/$(basename "$PARAMETER_FILE" .parameters)

dumpPaths "Files in environment before source configs" >> ${extendedLogFile}
env >> ${extendedLogFile}

## First source the job's PARAMETER_FILE (.parameter) with all the global variables
waitForFile "$PARAMETER_FILE"
source ${PARAMETER_FILE} || throw 200 "Error sourcing $PARAMETER_FILE"

dumpPaths "Files in environment after source configs" >> ${extendedLogFile}
env >> ${extendedLogFile}

if [[ ${outputFileGroup-false} != false && ${newGrpIsCalled-false} == false ]]; then
  export newGrpIsCalled=true

  if [[ -v LD_LIBRARY_PATH ]]; then
    export LD_LIB_PATH="$LD_LIBRARY_PATH"
  fi
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
  export TMP="$RODDY_SCRATCH"
  export TEMP="$RODDY_SCRATCH"
  export TMPDIR="$RODDY_SCRATCH"

  # Check
  _lock="$jobStateLogFile~"

  if [[ -z `which lockfile` ]]; then
    echo "Set lockfile commands to lockfile-create and lockfile-remove"
    useLockfile=false
    lockCommand=lockfile-create
    unlockCommand=lockfile-remove
  else
    echo "Using 'lockfile' command for locking"
    useLockfile=true
    lockCommand="lockfile -s 1 -r 50"
    unlockCommand="rm -f"
  fi

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

  # Create directories. DIR_TEMP is located in the execution store.
  mkdir -p ${DIR_TEMP} 2> /dev/null

  echo "Calling script ${WRAPPED_SCRIPT}"
  jobProfilerBinary=${JOB_PROFILER_BINARY-}
  [[ ${enableJobProfiling-false} == false ]] && jobProfilerBinary=""

  myGroup=`groups  | cut -d " " -f 1`
  outputFileGroup=${outputFileGroup-$myGroup}

  exitCode=0
  [[ ${disableDebugOptionsForToolscript-false} == true ]] && export WRAPPED_SCRIPT_DEBUG_OPTIONS=""
  echo "######################################################### Starting wrapped script ###########################################################"
  $jobProfilerBinary bash ${WRAPPED_SCRIPT_DEBUG_OPTIONS-} ${WRAPPED_SCRIPT} || exitCode=$?
  echo "######################################################### Wrapped script ended ##############################################################"
  echo "Exited script ${WRAPPED_SCRIPT} with value ${exitCode}"

  sleep 2

  ${lockCommand} $_lock;
  echo "${RODDY_JOBID}:${exitCode}:"`date +"%s"`":${TOOL_ID}" >> ${jobStateLogFile};
  ${unlockCommand} $_lock

  killChildProcesses

  # Set this in your command factory class, when roddy should clean up the dir for you.
  [[ ${RODDY_AUTOCLEANUP_SCRATCH-false} == "true" ]] && rm -rf ${RODDY_SCRATCH} && echo "Auto cleaned up RODDY_SCRATCH"

  [[ ${exitCode} -eq 100 ]] && echo "Finished script with 99 for compatibility reasons with Sun Grid Engine. 100 is reserved for SGE usage." && exit 99
  exit $exitCode

fi
