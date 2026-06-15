return {
    getDataDir = function()
        return os.getenv("QUICKRSS_TEST_DATA") or "/tmp/quickrss-test"
    end,
}
