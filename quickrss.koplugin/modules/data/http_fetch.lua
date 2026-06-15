-- QuickRSS: HTTP fetch utilities with bounded parallel downloads.
--
-- On Linux/macOS, parallel fetches run in forked subprocesses so each request
-- gets a fresh SSL stack (avoids fd leaks on e-readers).  Falls back to
-- sequential in-process fetches when fork is unavailable.
--
-- Public API:
--   HttpFetch.fetchRaw(url)              → body, err
--   HttpFetch.fetchMany(jobs, opts)      → { [id] = { body } | { error } }
--     jobs: { { id = string, url = string }, … }
--     opts: { concurrency, on_progress(done, total, id) }

local DataStorage = require("datastorage")
local ffiutil     = require("ffi/util")
local logger      = require("logger")
local lfs         = require("libs/libkoreader-lfs")
local socket      = require("socket")

local HttpFetch = {}

local TMP_DIR = DataStorage:getDataDir() .. "/quickrss/fetch-tmp"

local function canUseSubprocess()
    return jit.os == "Linux" or jit.os == "OSX"
end

local function ensureTmpDir()
    lfs.mkdir(DataStorage:getDataDir() .. "/quickrss")
    lfs.mkdir(TMP_DIR)
end

local function wipeTmpDir()
    local ok = lfs.attributes(TMP_DIR, "mode") == "directory"
    if not ok then return end
    for fname in lfs.dir(TMP_DIR) do
        if fname ~= "." and fname ~= ".." then
            os.remove(TMP_DIR .. "/" .. fname)
        end
    end
end

local function bodyPath(id)
    return TMP_DIR .. "/" .. id .. ".body"
end

-- Synchronous HTTPS GET.  Safe to call from parent or forked child.
function HttpFetch.fetchRaw(url)
    local https      = require("ssl.https")
    local ltn12      = require("ltn12")
    local socketutil = require("socketutil")
    local sink = {}
    socketutil:set_timeout(
        socketutil.LARGE_BLOCK_TIMEOUT,
        socketutil.LARGE_TOTAL_TIMEOUT
    )
    local ok, code, _, status = https.request{
        url  = url,
        sink = ltn12.sink.table(sink),
    }
    socketutil:reset_timeout()

    if not ok then return nil, tostring(code) end
    if code ~= 200 then
        return nil, "HTTP " .. tostring(code) .. " – " .. tostring(status)
    end
    return table.concat(sink), nil
end

local function fetchSequential(jobs, on_progress)
    local results = {}
    for i, job in ipairs(jobs) do
        local body, err = HttpFetch.fetchRaw(job.url)
        if err then
            results[job.id] = { error = err }
        else
            results[job.id] = { body = body }
        end
        if on_progress then on_progress(i, #jobs, job.id) end
    end
    return results
end

local function startSubprocessJob(job)
    local path = bodyPath(job.id)
    local url  = job.url
    local pid, read_fd = ffiutil.runInSubProcess(function(_, write_fd)
        local body, err = HttpFetch.fetchRaw(url)
        if err then
            ffiutil.writeToFD(write_fd, "E:" .. err, true)
        else
            local f = io.open(path, "wb")
            if not f then
                ffiutil.writeToFD(write_fd, "E:temp write failed", true)
                return
            end
            f:write(body)
            f:close()
            ffiutil.writeToFD(write_fd, "O", true)
        end
    end, true)
    if not pid then return nil end
    return { pid = pid, read_fd = read_fd, id = job.id, path = path }
end

local function collectJob(info)
    local status = ""
    if info.read_fd then
        status = ffiutil.readAllFromFD(info.read_fd) or ""
        info.read_fd = nil
    end
    if not ffiutil.isSubProcessDone(info.pid) then
        ffiutil.isSubProcessDone(info.pid, true)
    end

    if status:sub(1, 1) == "O" then
        local f = io.open(info.path, "rb")
        if not f then
            os.remove(info.path)
            return { error = "temp read failed" }
        end
        local body = f:read("*a")
        f:close()
        os.remove(info.path)
        return { body = body }
    end
    os.remove(info.path)
    if status:sub(1, 1) == "E" then
        return { error = status:sub(3) }
    end
    return { error = "subprocess failed" }
end

local function fetchParallel(jobs, concurrency, on_progress)
    ensureTmpDir()
    wipeTmpDir()

    local results  = {}
    local queue    = {}
    for _, job in ipairs(jobs) do table.insert(queue, job) end
    local active   = {}
    local done     = 0
    local total    = #jobs

    local function activeCount()
        local n = 0
        for _ in pairs(active) do n = n + 1 end
        return n
    end

    while #queue > 0 or activeCount() > 0 do
        while activeCount() < concurrency and #queue > 0 do
            local job = table.remove(queue, 1)
            local info = startSubprocessJob(job)
            if info then
                active[info.pid] = info
            else
                local body, err = HttpFetch.fetchRaw(job.url)
                if err then
                    results[job.id] = { error = err }
                else
                    results[job.id] = { body = body }
                end
                done = done + 1
                if on_progress then on_progress(done, total, job.id) end
            end
        end

        local finished = {}
        for pid, info in pairs(active) do
            local subprocess_done = ffiutil.isSubProcessDone(pid)
            local readable = info.read_fd
                and ffiutil.getNonBlockingReadSize(info.read_fd) ~= 0
            if subprocess_done or readable then
                table.insert(finished, pid)
            end
        end

        for _, pid in ipairs(finished) do
            local info = active[pid]
            active[pid] = nil
            results[info.id] = collectJob(info)
            done = done + 1
            if on_progress then on_progress(done, total, info.id) end
        end

        if #queue > 0 or activeCount() > 0 then
            socket.sleep(0.02)
        end
    end

    wipeTmpDir()
    return results
end

-- Fetch many URLs with bounded parallelism.
function HttpFetch.fetchMany(jobs, opts)
    opts = opts or {}
    if #jobs == 0 then return {} end

    local concurrency = opts.concurrency or 2
    concurrency = math.max(1, math.min(concurrency, 8))

    if concurrency == 1 or not canUseSubprocess() then
        return fetchSequential(jobs, opts.on_progress)
    end
    return fetchParallel(jobs, concurrency, opts.on_progress)
end

return HttpFetch
