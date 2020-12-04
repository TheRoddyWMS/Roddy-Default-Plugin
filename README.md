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
  - optionally, if `outputFileGroup` != "false", change to the requested group with `sg` and restart at setup (above)
  - source job-specific environment script (see "Environment Setup Support" below)
  - setup scratch directory
  - update the `jobStateLogfile.txt` using a lock-file
  - run the wrapped script using bash 
  - kill child-process still running after the wrapped script ended
  - update the `jobStateLogfile.txt` with the job's exit code
  - exit

## Environment Setup Support

### Base Environment Script

The job is started with the default environment configured with your job submission system, also depending on the Roddy configuration.

The `baseEnvironmentScript` serves as kind of general configuration of your cluster environment. Usually it sources something like `/etc/profile` or `$HOME/.profile` or `$HOME/.bashrc`. Note that the `baseEnvironmentScript` variable is taken from Roddy's `applicationProperties.ini`, not from the XML configuration files.

### Workflow- and Job-Environment Scripts

After the base environment script and the job-parameter file were sourced, the wrapper script checks whether you have a dedicated environment script defined for the whole workflow or the specific cluster job. These scripts are variables defined in one of the configuration XMLs or on the commandline via the `--cvalues` parameter.

Workflow-environment scripts define the environment for all jobs of a workflow. Job-environment scripts define the environment for individual jobs and take precedence over the workflow-environments.

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

This will declare two environment scripts and select the "workflowEnvironment_conda" as the default environment. Via a configuration value, the user can then select the `lsf.sh` by defining  e.g. `--cvalue="workflowEnvironmentScript:workflowEnvironment_lsf"`. Here both environment scripts need to be located in the `resources/environments` directory in the plugin, which is copied to the execution host.

You may want to specify dedicated scripts for individual cluster jobs. These take precedence over the global workflow environment script. For instance, the following defines a tool as environment script for the `correctGcBias` cluster job (which is also defined as tool).

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

Sometimes having to modify the plugin in place is not possible or desirable, in particular during development. In this case, you can also specify the environment script directly in the configuration value like in "/path/to/develEnv.sh". This path should be absolute and must be available on the execution host. This possibility is only available since version 1.3.0.
 
The logic to discriminate between these three cases is as follows:
  - the value contains a '/': this is a direct path. This only works since version 1.3.0.
  - the value starts with '${': this is a TOOL_ path. Since version 1.3.0 the matching is on `${TOOL_}`.
  - compose the the `TOOL_` variable name from the job-name, like described before.

### Environment Parametrization

The environment script is simply `source`'d, so you can access variables from the parameter-file (`PARAMETER_FILE`, sourced before; see above) from within that script. For instance, you may want to also specify the conda environment name in the XML:

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

Bash functions can also get exported with `export -f`.

Note that due to the mentioned bug in Bash with exported array variables, something like `export -a` won't work, unless you use a very recent Bash version. We suggest here to take the same strategy as the `PARAMETER_FILE` does, namely to export them as quoted Bash array string

```bash
export arrayStringVar="(a b c d)"
```

and then cast them into Bash arrays in your wrapped script with

```bash
declare -a arrayVar="$arrayStringVar"
```

### Debugging and Error Behaviour
  
The `debugWrapInScript` variable -- defaulting to `false` -- turns on the `set +xv` verbosity shell options. 
  
The `baseEnvironmentScript` is sourced with relaxed values for `set`, i.e. with `set +ue`, because often files like `/etc/profile` are not under the control of the person running the workflow. Changes to the `set` options in the `baseEnvironmentScript` are not inherited by subsequent code in the  `wrapInScript.sh`.

The environment script has the same values for the shell options set via `set` in Bash, as the wrapper. In particular this means that `errexit` is set. Changes in the environment script *are* inherited by subsequent code in the `wrapInScript.sh`.
  
It is possible to run the same command that Roddy runs as remote job from the interactive command line. The wrapper script recognizes that it is run in an interactive session and avoids an exitting of the Bash upon errors (i.e. `set +e` is set) but should otherwise behave exactly as if run by `bsub` or `qsub`.

Finally the wrapped script has debugging options `WRAPPED_SCRIPT_DEBUG_OPTIONS`. For convenience, the application of these options can be turned off by the `disableDebugOptionsForToolscript`.

### Execution

As stated previously, the wrapped script is executed by Bash. This means you can use a shebang-line to select an arbitrary interpreter, e.g. one you have pulled into the environment via the `baseEnvironmentScript` or the workflow- or job-specific environments scripts.
  
### Conventions

The following conventions are nothing more than that and are currently not enforced by Roddy:

* use camel-case tool names starting with small letters (e.g. "correctGcBias")
* append the arbitrary environment name that you want to use to the tool name to get the name of the environment variable
* describe the environment in the `description` attribute of the `cvalue` tag
* the environment setup scripts is located in the "environments" subdirectory of the workflow directory in the plugin

## Changelog

* 1.2.2-5

  - Turn off debugging options when sourcing environment files
  - Refactored lockfile code in `wrapInScript.sh`
  - Report if user is not member of `outputFileGroup`.

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
