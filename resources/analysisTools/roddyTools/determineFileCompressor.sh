#!/bin/sh

source "${TOOL_DEFAULT_PLUGIN_LIB:?No TOOL_DEFAULT_PLUGIN_LIB defined}"

setCompressionToolsBasedOnFileCompression "${TEST_FILE}"
