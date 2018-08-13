-- Chisel description
description = "Lists every command that is launched by users originally logged in via SSH, plus every directory the users visit. Output is in JSON format for easy parsing.";
short_description = "Display SSH user activity";
category = "Security";

-- Chisel argument list
args = {}

require "common"
json = require("dkjson")

MAX_ANCESTOR_NAVIGATION = 16
max_depth = -1

-- Argument notification callback
function on_set_arg(name, val)
    return true
end

-- Initialization callback
function on_init()
    -- Request the fields needed for this chisel
    fpid = chisel.request_field("proc.pid")
    fppid = chisel.request_field("proc.ppid")
    floginshellid = chisel.request_field("proc.loginshellid")
    fenv = chisel.request_field("proc.env")
    fetype = chisel.request_field("evt.type")
    fexe = chisel.request_field("proc.exe")
    fargs = chisel.request_field("proc.args")
    fdirectory = chisel.request_field("evt.arg.path")
    fuser = chisel.request_field("user.name")
    fdtime = chisel.request_field("evt.datetime")
    fcontainername = chisel.request_field("container.name")
    fcontainerid = chisel.request_field("container.id")

    -- dynamically request fields for up to 16 ancestor names and pids.
    -- just to prevent copy and pasting the lines like above.
    fanames = {}
    fapids = {}
    for j = 0, MAX_ANCESTOR_NAVIGATION do
        fanames[j] = chisel.request_field("proc.aname[" .. j .. "]")
        fapids[j] = chisel.request_field("proc.apid[" .. j .. "]")
    end

    -- The -pc or -pcontainer options was supplied on the cmd line
    print_container = sysdig.is_print_container_data()

    -- set the filter
    chisel.set_filter("proc.aname=sshd and evt.failed=false and ((evt.type=execve and evt.dir=<) or (evt.type=chdir and evt.dir=< and proc.name contains sh and not proc.name contains sshd))")

    return true
end

-- Event parsing callback
function on_event()
    local user = evt.field(fuser)
    local dtime = evt.field(fdtime)
    local pid = evt.field(fpid)
    local ppid = evt.field(fppid)
    local containername = evt.field(fcontainername)
    local containerid = evt.field(fcontainerid)
    local exe = evt.field(fexe)
    local args = evt.field(fargs)
    local type = evt.field(fetype)
    local is_chdir = evt.field(fetype) == "chdir"
    local loginshellid = evt.field(floginshellid)
    local penv = evt.field(fenv)
    local sudouser=string.match(penv, "SUDO_USER=%S+")

    local aname

    if user == nil then
        user = "NA"
    end

    local output = {
        evt_pid = pid,
        evt_time = dtime,
        evt_type = type,
        evt_user = user,
        evt_loginshell = loginshellid
    }
    if containerid ~= nil then
        output["evt_containerid"] = containerid
    end
    if containername ~= nil then
        output["evt_containername"] = containername
    end
    if sudouser ~= nil then
        -- cut off the SUDO_USER= (10 chars) at the beginning, start from char 11
        output["evt_sudouser"] = string.sub(sudouser, 11)
    end

    -- there is no exe/args for chdir, but on the output side that distinction is not very useful,
    -- so we construct them here
    if is_chdir then
        output["evt_exe"] = "cd"
        output["evt_args"] = evt.field(fdirectory)
    else
        output["evt_exe"] = exe
        output["evt_args"] = args
    end

    -- traverse the parent processes and record their names and pids (flattened to a name (pid) string)
    -- until we either reach sshd or the top
    local ancestors = {}
    for j = 1, MAX_ANCESTOR_NAVIGATION do
        aname = evt.field(fanames[j])
        if aname == nil then
            -- top level ancestor reached
            break
        else
            table.insert(ancestors, aname .. " (" .. evt.field(fapids[j]) .. ")")
            -- no need to go up higher, break out of the loop
            if aname == "sshd" then
                break
            end
        end
    end

    output["evt_ancestors"] = ancestors
    -- Do not indent the json, because there might be tools down the line not expecting this.
    local json = json.encode(output, { indent = false })
    -- Write JSON to stdout and flush. This prevents any underlying buffering from writing
    -- partial JSON.
    io.write(json)
    io.write("\n")
    io.flush()
    return true
end


-- Called by the engine at the end of the capture (Ctrl-C)
function on_capture_end()
    return true
end