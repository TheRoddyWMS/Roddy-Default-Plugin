TOOL_DEFAULT_PLUGIN_LIB="${SRC_ROOT:?No SRC_ROOT defined}/analysisTools/roddyTools/lib.sh"

source "$TOOL_DEFAULT_PLUGIN_LIB"

testName=DefaultPluginTest

testSetCompressionToolsBasedOnFileCompression_ascii() {
    export -f setCompressionToolsBasedOnFileCompression
    local tmp=$(mktemp -d "$testName-XXXXXXX")

    echo "test" > "$tmp/x"
    local output=$(bash -i -c "setCompressionToolsBasedOnFileCompression $tmp/x")
    setCompressionToolsBasedOnFileCompression "$tmp/x" > /dev/null

    assertEquals "ASCII" "$output"
    assertEquals "$UNZIPTOOL" "cat"
    assertEquals "$UNZIPTOOL_OPTIONS" ""
    assertEquals "$ZIPTOOL" "head"
    assertEquals "$ZIPTOOL_OPTIONS" " -n E"

    rm -Rf "$tmp"
}

testSetCompressionToolsBasedOnFileCompression_gzip() {
    export -f setCompressionToolsBasedOnFileCompression
    local tmp=$(mktemp -d "$testName-XXXXXXX")

    echo "test" > "$tmp/x"
    gzip "$tmp/x"
    local output=$(bash -i -c "setCompressionToolsBasedOnFileCompression $tmp/x.gz")
    setCompressionToolsBasedOnFileCompression "$tmp/x.gz" > /dev/null

    assertEquals "gzip-compression" "$output"
    assertEquals "$UNZIPTOOL" "gunzip"
    assertEquals "$UNZIPTOOL_OPTIONS" " -c"
    assertEquals "$ZIPTOOL" "gzip"
    assertEquals "$ZIPTOOL_OPTIONS" " -c"

    rm -Rf "$tmp"
}

testSetCompressionToolsBasedOnFileCompression_bzip2() {
    export -f setCompressionToolsBasedOnFileCompression
    local tmp=$(mktemp -d "$testName-XXXXXXX")

    echo "test" > "$tmp/x"
    bzip2 "$tmp/x"
    local output=$(bash -i -c "setCompressionToolsBasedOnFileCompression $tmp/x.bz2")
    setCompressionToolsBasedOnFileCompression "$tmp/x.bz2" > /dev/null

    assertEquals "bzip2-compression" "$output"
    assertEquals "$UNZIPTOOL" "bunzip2"
    assertEquals "$UNZIPTOOL_OPTIONS" " -c -k"
    assertEquals "$ZIPTOOL" "bzip2"
    assertEquals "$ZIPTOOL_OPTIONS" " -c -k"


    rm -Rf "$tmp"
}



source ${SHUNIT2:?Oops}
