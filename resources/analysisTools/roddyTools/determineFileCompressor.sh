#!/bin/sh
#
# Copyright (c) 2020 German Cancer Research Center (DKFZ).
#
# Distributed under the MIT License (license terms are at https://github.com/DKFZ-ODCF/AlignmentAndQCWorkflows).
#

source "${TOOL_DEFAULT_PLUGIN_LIB:?No TOOL_DEFAULT_PLUGIN_LIB defined}"

setCompressionToolsBasedOnFileCompression "${TEST_FILE}"
