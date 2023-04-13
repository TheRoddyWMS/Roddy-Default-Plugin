# Default Roddy Plugin

The root of all Roddy plugins, including the PluginBase plugin.

All top-level tools or scripts that are supposed to be started on the cluster by Roddy are actually not directly started, but are wrapped by the `resources/roddyTools/wrapInScript.sh` contained in this plugin.

## Dependencies

You need at least Bash 4.2 for running the `wrapInScript.sh`.

## General Structure

The wrapper script has the following general structure

  - setup
  - source `baseEnvironmentScript` (e.g. `/etc/profile`)
  - source the job parameter file (`PARAMETER_FILE`)
  - optionally, if `outputFileGroup` != "false", change to the requested group with `sg` and restart the script at the "setup" step (above)
  - source job-specific environment script (see "Environment Setup Support" below)
  - setup scratch directory
  - update the `jobStateLogfile.txt` using a lock-file
  - run the wrapped script using bash or apptainer (dependent on `outerEnvironment=host` or `outerEnvironment=apptainer`)
  - kill child-process still running after the wrapped script ended
  - update the `jobStateLogfile.txt` with the job's exit code
  - exit

## Environment Setup Support

### Base Environment Script

Each job is started with the default environment configured in you `applicationProperties.ini` in the `baseEnvironmentScript` variable. The `baseEnvironmentScript` serves as kind of general configuration of your cluster environment. Usually you will use a script like `/etc/profile` or `$HOME/.profile` or `$HOME/.bashrc`. 

Note that often the `baseEnvironmentScript` is not under your control and may be sensitive for certain environment options, such as `set -e` or `set -u`. Therefore, error checks and logging options, which are turned on in the `wrapInScript.sh` if you set `debugWrapInScript=true`, will be turned off while reading the base environment. 

### Workflow- and Job-Environment Scripts

After the base environment script and after the job-parameter file were sourced, the wrapper script checks whether you have a dedicated environment script defined for the whole workflow or this specific cluster job. These environment scripts defined in one of the configuration XMLs or on the commandline via the `--cvalues` parameter.

The "workflow-environment" script defines the environment for all jobs of the workflow. By contrast, "job-environment" scripts define the environment for individual jobs and take precedence over the workflow-environments.

To define a workflow-level environment setup script, you can add lines like the following to your XMLs:

```xml
<configurationvalues>
  <cvalue name="workflowEnvironmentScript" value="workflowEnvironment_conda" type="string"
          description="Use 'workflowEnvironment_conda' for a generic Conda environment."/>
</configurationvalues>
<processingTools>
   <tool name="workflowEnvironment_conda" value="conda.sh" basepath="environments"/>
   <tool name="workflowEnvironment_lsf" value="lsf.sh" basepath="environments"/>
</processingTools>
```

This will declare two environment scripts and select the "workflowEnvironment_conda" as the environment to use. The user can still select `lsf.sh` as workflow environment by defining  e.g. `--cvalue="workflowEnvironmentScript:workflowEnvironment_lsf"` on the command line. In this example, environment scripts need to be located in the `resources/environments` directory in the plugin, which is copied to the execution host.

You may want to specify dedicated job-environment scripts for individual cluster jobs. These take precedence over the global workflow environment script. For instance, the following defines a tool as environment script for the `correctGcBias` cluster job (which is also defined as tool).

```xml
<configurationvalues>
    <cvalue name="correctGcBiasEnvironmentScript" value="${TOOL_CORRECT_GC_BIAS_ENVIRONMENT_CONDA}" type="string"/>
</configurationvalues>
<processingTools>
  <tool name="correctGcBiasEnvironment_conda" value="conda-correctGcBias.sh" basepath="environments"/>
</processingTools>
``` 

Internally, the tool names are mapped to a `TOOL_` bash variable according to the following rules:
  - inserting an underscore '\_' before all capitals, 
  - changing all letters to upper-case, and 
  - prepending "TOOL\_" before the name.
  
It is also possible, to refer to the tool by using a configuration value of the form `${TOOL_WORKFLOW_ENVIRONMENT_CONDA}`. This form is occasionally used in existing plugins, but we advise you to use the first simpler form.

Sometimes having to modify the plugin in place is not possible or desirable, in particular during development. In this case, you can also specify the environment script directly in the configuration value like in "/path/to/develEnv.sh". This path should be absolute and must be available on the execution host. This possibility is only available since version 1.2.2-5 of this plugin.
 
The logic to discriminate between these three cases is as follows:
  - the value contains a '/': this is a direct path. This only works since version 1.2.2-5.
  - the value starts with '${': this is a TOOL_ path. Since version 1.2.2-5 the matching is on `${TOOL_}`.
  - compose the the `TOOL_` variable name from the job-name, like described above.

### Environment Parametrization

The environment script is simply `source`'d, so you can access variables from the parameter-file (`PARAMETER_FILE`, sourced before; see above) from within that script. For instance, you have a `conda.sh` that activates a Conda environment, but you want to keep the environment name configurable. You can then the conda environment name in the XML:

```xml
<cvalue name="condaEnvironmentName" value="myWorkflow" type="string"
        description="Name of the Conda environment on the execution hosts. Used by the environment setup script conda.sh defined as tool below."/>
```

Then your `conda.sh` may look like this:

```bash
source activate "$condaEnvironmentName"
```

### Exporting Variables from the Environment Script

The environment setup scripts are mostly useful for setting up environment variables that can be used in the wrapped script, which does the actual job for you.

To achieve this Bash variables need to be exported with the `export` declaration. 

Sometimes it can be useful to define a Bash function in the environment script, for use in the wrapper. These Bash functions can get exported with `export -f`. An example is a wrapper function for a tool with a complex call which you want to wrap for better readability in your workflow code.

Note that due to a bug in Bash with exported array variables in Bash <4.4, something like `export -a` won't work. We suggest here to take the same strategy as the `PARAMETER_FILE` does, namely to export them as quoted Bash array string

```bash
export arrayStringVar="(a b c d)"
```

and then cast this string into a Bash arrays in your wrapped script with

```bash
declare -a arrayVar="$arrayStringVar"
```

### Debugging and Error Behaviour
  
The `debugWrapInScript` variable -- defaulting to `false` -- turns on the `set +xv` verbosity shell options. 
  
The `baseEnvironmentScript` is sourced with relaxed values for `set`, i.e. with `set +ue`, because often files like `/etc/profile` are not under the control of the person running the workflow. Conversely, changes to the `set` options in the `baseEnvironmentScript` are not inherited by subsequent code in the  `wrapInScript.sh`.

The environment script has the same values for the shell options set via `set` in Bash, as the wrapper. In particular this means that `errexit` is set. Changes in the environment script *are* inherited by subsequent code in the `wrapInScript.sh`.
  
It is possible to run the same command that Roddy runs as remote job from the interactive command line. The wrapper script recognizes that it is run in an interactive session and avoids an exiting of the Bash upon errors (i.e. `set +e` is set) but should otherwise behave exactly as if run by `bsub` or `qsub`.

Finally, the wrapped script has debugging options `WRAPPED_SCRIPT_DEBUG_OPTIONS`. For convenience, the application of these options can be turned off by the `disableDebugOptionsForToolscript`.

### Wrapped-Script Execution

As stated previously, the wrapped script is executed by Bash. This means you can use a shebang-line to select an arbitrary interpreter, e.g. one you have pulled into the environment via the `baseEnvironmentScript` or the workflow- or job-specific environments scripts.
  
### Singularity/Apptainer

The cluster jobs can be wrapped in an Singularity/Apptainer container. 

Specifically, the wrapper script is normally started in the shell. As usually, it may decide to restart itself with the group that was specified in `outputFileGroup`.

Usually the `WRAPPED_SCRIPT` is executed by Bash directly, but if `outerEnvironment` is "apptainer" (or "singularity"), then additionally, the executing Bash is wrapped by a call to `singularity` (currently, both options call the `singularity` binary). The working directory in the container is the same working directory that is used when executing the wrap-in script. Currently, only a single container can be specified with `container`.

By default, the `inputAnalysisBaseDirectory` is mounted read-only, and the `outputAnalysisBaseDirectory` read-write. Remember that these directory paths are configurable and may be composed of different pieces of information (see `default.xml` in this plugin).  If both paths point to the same directory (after `readlink -f`!) then this directory is bound read-write into container.

You may specify additional directories to be mounted read-only into the container, e.g. for reference data or a software stack. This is done with `containerMounts` set to a list of paths formatted as Bash array, i.e. `(path1 path2 path3 [etc.])`. Don't worry about duplicates in that list: The wrapper script normalizes all paths with `readlink -f`, fails on non-existing paths, and then de-duplicates the list.

The same parameters as for execution in a Bash shell can be used also for executing in an apptainer container, e.g. `WRAPPED_SCRIPT_DEBUG_OPTIONS`.

Note that it is possible to export also the `PATH` and `LD_LIBRARY_PATH` environment variables into the container. This is not done by default, but only if `containerExportPath` is set to `true`. Usually you only need this, 

### Conventions

The following conventions are nothing more than that and are currently not enforced by Roddy:

* use camel-case tool names starting with small letters (e.g. "correctGcBias")
* append the arbitrary environment name that you want to use to the tool name to get the name of the environment variable
* describe the environment in the `description` attribute of the `cvalue` tag
* the environment setup scripts is located in the "environments" subdirectory of the workflow directory in the plugin

## Changelog

* 1.3

  - Minor: Add Apptainer/Singularity support.
  - Minor: Changed some wrapper exit codes from 100 to 101, because 100 is reserved for SGE.

* 1.2.2-5

  - Turn off debugging options when sourcing environment files. This allows using environment scripts that fail because of `set -u`). If your setup script needs `set -u` turn it on in your script.
  - Refactored lockfile code in `wrapInScript.sh`
  - Report if user is not member of `outputFileGroup`.
  - Allow defining environment scripts outside the plugin `resources/` directory.

* 1.2.2-4

  - `buildversion.txt` did not correctly reflect the version 1.2.2
  - allow for /ad hoc/ custom environment scripts 

* 1.2.2-3

  - get Bash via `/usr/bin/env`
  - using a bash 4 feature to do the childprocess listing
  - child-process killing 

* 1.2.2-2

  - removed unused `preventJobExecution` variable
  - extended checks for `RODDY_SCRATCH`
  - add `killBackgroundJobs` to deal with processes not killed by batch-processing system
  - set generic temporary variables (`TMP`, `TMPDIR`, `TEMP`) to scratch
  - set {input,output}AnalysisBaseDirectory defaults

* 1.2.2-1

  - updated dependency to Roddy 3.0 (note Roddy "2.4" is a development-only version)

* 1.2.2

  - added shunit2 tests
  - Remove autocheckpoint code
  - Improve debugging
  - `disableDebugOptionsForToolscript` to turn off wrapped script debugging
  - fixed typo that caused `2`-directory to be created in user's home
  - source `baseEnvironmentScript`
  - remove `CONFIG_FILE` references (i.e. `runtimeConfig.sh`) 
  - deal with environments that don't have LD_LIBRARY_PATH undefined when set -u is configured
  
* 1.2.1

  - check LD_LIBRARY_PATH definition before exporting, otherwise error with set -u

* 1.2.0

  - `defaultScratchDir` removed
  - error redirection into stderr
  - fixed errors if `debugOptionsUseUndefinedVariableBreak` is set
  - write environment into extended logs
  - 
  
* 1.0.34

  - require Roddy 2.4 (=3.0) and PluginBase 1.0.29
  - "native" workflow support
  - removed some older scripts not used anymore (fileStreamBuffer.sh, findOpenPort.sh, jobEpilogue.sh, jobPostEpilogue.sh, streamBuffer.sh)
  - module support directly in wrapInScript.sh
  - check parameter and configuration file usability
  
* 1.0.33

  - first Github version of the plugin
  - Roddy 2.3
