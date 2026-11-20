-- Tasks: more than one Windows 3.1 program at once (Program Manager and
-- the programs it starts, such as Control Panel), as Windows 3.1 ran them:
-- cooperatively. Each task runs in a Lua coroutine on its own registers
-- and stack; it gives way in GetMessage/PeekMessage when nothing is
-- waiting for it, and the scheduler resumes whichever task has work.
--
-- A message sent to another task's window runs that task's window
-- procedure on its own stack (its registers), from the sender's coroutine,
-- with the receiver marked busy until it returns.

local cpu = require("recomp.cpu")

local tasks = {list = {}}

local kernel, user

local function mods()
    kernel = kernel or require("win16.kernel")
    user = user or require("win16.user")
end

-- Makes `t` the current task: the kernel's and USER's per-task state follows.
function tasks.switch(t)
    mods()
    local cur = kernel.task
    if cur == t then return end
    if cur then cur.modal, cur.quit = user.modal, user.quit end
    kernel.task = t
    user.task, user.module = t, t and t.module
    if t then user.modal, user.quit = t.modal, t.quit end
end

-- Adds a task started by kernel.startTask; it runs from its entry point
-- when the scheduler first gets to it.
function tasks.add(t)
    t.fresh = true
    t.lent = 0
    t.co = coroutine.create(function() cpu.run(t.R) end)
    tasks.list[#tasks.list + 1] = t
    if not tasks.main then tasks.main = t end
    return t
end

-- Does task t have anything to do?
function tasks.ready(t)
    mods()
    if t.fresh or t.quit or (t == kernel.task and user.quit) then return true end
    if #user.input > 0 then return true end
    for _, m in ipairs(user.posted) do if user.taskOfMsg(m) == t then return true end end
    for _, m in ipairs(user.translated) do if user.taskOfMsg(m) == t then return true end end
    if user.needsPaint(t) then return true end
    if user.timerDue and user.timerDue(t) then return true end
    if t == tasks.main and user.idle then return true end
    return false
end

-- Called by a task with nothing to do: lets the others run. Returns at
-- once when there is no other task (or no coroutine to leave).
function tasks.yield()
    if #tasks.list < 2 or not coroutine.isyieldable() then return false end
    mods()
    local me = kernel.task
    coroutine.yield()
    tasks.switch(me)
    return true
end

-- Whether some other task is waiting to run.
function tasks.othersReady()
    mods()
    for _, t in ipairs(tasks.list) do
        if t ~= kernel.task and t.lent == 0 and coroutine.status(t.co) == "suspended" and tasks.ready(t) then
            return true
        end
    end
    return false
end

-- A task's program ended: its windows go, and the task.
function tasks.kill(t)
    mods()
    for i, x in ipairs(tasks.list) do
        if x == t then table.remove(tasks.list, i) break end
    end
    local prev = kernel.task
    tasks.switch(t)
    local list = {}
    for _, w in ipairs(user.desktop.children) do
        if w.task == t and not w.destroyed then list[#list + 1] = w end
    end
    for _, w in ipairs(list) do pcall(user.destroy, w) end
    user.posted = (function()
        local keep = {}
        for _, m in ipairs(user.posted) do if user.taskOfMsg(m) ~= t then keep[#keep + 1] = m end end
        return keep
    end)()
    tasks.switch(prev ~= t and prev or tasks.main)
    host.log("Task ended: " .. tostring(t.path))
    if user.taskEnded then user.taskEnded(t) end
end

-- Runs a 16-bit callback on task t's stack (for a window procedure of t's
-- called while another task is current).
function tasks.callOn(t, fn)
    mods()
    local prev = kernel.task
    if not t or t == prev then return fn(prev) end
    t.lent = t.lent + 1
    tasks.switch(t)
    local ok, a, b = pcall(fn, t)
    tasks.switch(prev)
    t.lent = t.lent - 1
    if not ok then error(a, 0) end
    return a, b
end

-- The scheduler: runs until the first task (Program Manager) ends.
-- Returns its exit code, or raises what ended it.
function tasks.run()
    mods()
    while true do
        local ran = false
        for _, t in ipairs({table.unpack(tasks.list)}) do
            if t.lent == 0 and coroutine.status(t.co) == "suspended" and tasks.ready(t) then
                t.fresh = nil
                tasks.switch(t)
                ran = true
                local ok, err = coroutine.resume(t.co)
                local dead = coroutine.status(t.co) == "dead"
                if not ok or dead then
                    if t == tasks.main then
                        if ok then return 0 end
                        error(err, 0)
                    end
                    -- --exit-after ends everything, whichever task was running
                    if not ok and type(err) == "table" and err.quit then error(err, 0) end
                    if not ok and not (type(err) == "table" and err.exit) then
                        host.log("Task " .. tostring(t.path) .. " stopped: " .. tostring(err))
                    end
                    tasks.kill(t)
                end
            end
        end
        if not ran then
            user.present()
            user.pumpHost(20)
        end
    end
end

return tasks
