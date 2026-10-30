--[[--
JNI glue for org.koreader.mdict.HtmlRenderer (android/src), loaded at runtime
from the plugin's mdict-bridge.dex with a DexClassLoader. KOReader's launcher
does not need to know about it.

All strings cross JNI as UTF-8 byte arrays, which avoids modified UTF-8.
]]

local ffi = require("ffi")

local Bridge = {}
Bridge.__index = Bridge

local CLASS = "org.koreader.mdict.HtmlRenderer"

local METHODS = {
    open = "(III)V",
    load = "(I[B[B[B[B)V",
    call = "(II[B[B)V",
    poll = "(I)[B",
    drain = "()V",
    provide = "(I[B)V",
    capture = "(IILjava/nio/ByteBuffer;II)V",
    close = "(I)V",
    closeAll = "()V",
    playAudio = "([B)V",
    stopAudio = "()V",
}

local function android_module()
    local ok, android = pcall(require, "android")
    if ok and type(android) == "table" and android.app and android.app.activity ~= nil then
        return android
    end
end

function Bridge.isAvailable()
    return android_module() ~= nil
end

local function check(env, what)
    local E = env[0]
    if E.ExceptionCheck(env) ~= 0 then
        E.ExceptionDescribe(env)
        E.ExceptionClear(env)
        error("JNI exception in " .. what, 0)
    end
end

local function jstring(env, s)
    return env[0].NewStringUTF(env, s)
end

local function lua_string(jni, js)
    if js == nil then return nil end
    local s = jni:to_string(js)
    jni.env[0].DeleteLocalRef(jni.env, js)
    return s
end

-- FNV-1a of a string, as hex: names the dex copy by its content.
local function content_hash(data)
    local bit = require("bit")
    local h = bit.tobit(0x811c9dc5)
    for i = 1, #data do
        local x = bit.bxor(h, data:byte(i))
        h = bit.tobit(bit.lshift(x, 24) + x * 403) -- x * 16777619 mod 2^32, exactly
    end
    return bit.tohex(h)
end

local function write_file(dst, data)
    local fo = io.open(dst .. ".tmp", "wb")
    if not fo then return false end
    fo:write(data)
    fo:close()
    return os.rename(dst .. ".tmp", dst)
end

pcall(ffi.cdef, "int chmod(const char *path, unsigned int mode);")

--- Loads the dex and creates the Java renderer. Returns a bridge, or nil and an error.
function Bridge.new(dex_path)
    local android = android_module()
    if not android then return nil, "not running on Android" end
    local self = setmetatable({ android = android, jni = android.jni, vm = android.app.activity.vm }, Bridge)
    local ok, err = pcall(function()
        self:_with(function(jni)
            local env = jni.env
            local E = env[0]
            local activity = android.app.activity.clazz

            -- code cache dir: private, so the dex cannot be swapped by other apps
            local dir = lua_string(jni, jni:callObjectMethod(
                jni:callObjectMethod(activity, "getCodeCacheDir", "()Ljava/io/File;"),
                "getAbsolutePath", "()Ljava/lang/String;"))
            check(env, "getCodeCacheDir")
            local fi = io.open(dex_path, "rb")
            if not fi then error("missing " .. dex_path, 0) end
            local data = fi:read("*a")
            fi:close()
            local target = string.format("%s/mdict-bridge-%s.dex", dir, content_hash(data))
            local existing = io.open(target, "rb")
            if existing then
                existing:close()
            elseif not write_file(target, data) then
                error("cannot copy dex to " .. target, 0)
            end
            ffi.C.chmod(target, tonumber("444", 8)) -- loaded code must not be writable (Android 14)

            local parent = jni:callObjectMethod(activity, "getClassLoader", "()Ljava/lang/ClassLoader;")
            local dcl = E.FindClass(env, "dalvik/system/DexClassLoader")
            check(env, "FindClass DexClassLoader")
            local ctor = E.GetMethodID(env, dcl, "<init>",
                "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/ClassLoader;)V")
            local args = ffi.new("jvalue[4]")
            args[0].l = jstring(env, target)
            args[1].l = jstring(env, dir)
            args[2].l = nil
            args[3].l = parent
            local loader = E.NewObjectA(env, dcl, ctor, args)
            check(env, "new DexClassLoader")
            local load_class = E.GetMethodID(env, dcl, "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;")
            local a1 = ffi.new("jvalue[1]")
            a1[0].l = jstring(env, CLASS)
            local cls = E.CallObjectMethodA(env, loader, load_class, a1)
            check(env, "loadClass " .. CLASS)
            local init = E.GetMethodID(env, cls, "<init>", "(Landroid/app/Activity;)V")
            check(env, "HtmlRenderer.<init>")
            a1[0].l = activity
            local obj = E.NewObjectA(env, cls, init, a1)
            check(env, "new HtmlRenderer")
            self.class = E.NewGlobalRef(env, cls)
            self.object = E.NewGlobalRef(env, obj)
            self.loader = E.NewGlobalRef(env, loader)
            self.mid = {}
            for name, sig in pairs(METHODS) do
                self.mid[name] = E.GetMethodID(env, cls, name, sig)
                check(env, "method " .. name)
            end
        end)
    end)
    if not ok then return nil, tostring(err) end
    return self
end

--- Runs fn(jni) with this thread attached to the VM. Nested calls reuse the attachment.
function Bridge:_with(fn)
    if self.attached then return fn(self.jni) end
    return self.jni:context(self.vm, function(jni)
        self.attached = true
        local ok, a, b = pcall(fn, jni)
        self.attached = false
        if not ok then error(a, 0) end
        return a, b
    end)
end

--- Runs fn() with the thread attached, so a burst of calls (an event loop) attaches once.
function Bridge:session(fn)
    return self:_with(function() return fn() end)
end

local function bytes(env, s)
    if s == nil then return nil end
    local E = env[0]
    local arr = E.NewByteArray(env, #s)
    E.SetByteArrayRegion(env, arr, 0, #s, ffi.cast("const jbyte*", s))
    return arr
end

-- Calls a void method; spec lists argument kinds: "i" int, "b" byte[] (Lua string), "l" jobject.
function Bridge:_void(name, spec, ...)
    local n = select("#", ...)
    local params = { ... }
    return self:_with(function(jni)
        local env = jni.env
        local E = env[0]
        local args = ffi.new("jvalue[?]", math.max(n, 1))
        local locals = {}
        for k = 1, n do
            local kind, v = spec:sub(k, k), params[k]
            if kind == "i" then
                args[k - 1].i = v
            elseif kind == "b" then
                local arr = bytes(env, v)
                args[k - 1].l = arr
                locals[#locals + 1] = arr
            else
                args[k - 1].l = v
            end
        end
        E.CallVoidMethodA(env, self.object, self.mid[name], args)
        for _, l in ipairs(locals) do if l ~= nil then E.DeleteLocalRef(env, l) end end
        check(env, name)
    end)
end

function Bridge:open(slot, w, h) self:_void("open", "iii", slot, w, h) end

function Bridge:load(slot, base_url, html, cache_root, files_json)
    self:_void("load", "ibbbb", slot, base_url, html, cache_root, files_json or "")
end

function Bridge:call(slot, id, op, args_json) self:_void("call", "iibb", slot, id, op, args_json) end

function Bridge:provide(rid, path) self:_void("provide", "ib", rid, path or "") end

function Bridge:close(slot) self:_void("close", "i", slot) end

function Bridge:closeAll() self:_void("closeAll", "") end

--- Plays an audio file with Android's MediaPlayer (stopping the one playing).
function Bridge:playAudio(path) self:_void("playAudio", "b", path) end

function Bridge:stopAudio() self:_void("stopAudio", "") end

function Bridge:drain() self:_void("drain", "") end

--- Next event (a JSON string) or nil after timeout_ms.
function Bridge:poll(timeout_ms)
    return self:_with(function(jni)
        local env = jni.env
        local E = env[0]
        local a = ffi.new("jvalue[1]")
        a[0].i = timeout_ms or 0
        local arr = E.CallObjectMethodA(env, self.object, self.mid.poll, a)
        check(env, "poll")
        if arr == nil then return nil end
        local len = E.GetArrayLength(env, arr)
        local buf = ffi.new("uint8_t[?]", math.max(len, 1))
        E.GetByteArrayRegion(env, arr, 0, len, ffi.cast("jbyte*", buf))
        E.DeleteLocalRef(env, arr)
        return ffi.string(buf, len)
    end)
end

--- Draws the slot into memory at ptr (w*h RGBA pixels). The memory must stay
-- alive until the "captured" event arrives.
function Bridge:capture(slot, id, ptr, w, h)
    self:_with(function(jni)
        local env = jni.env
        local E = env[0]
        local buf = E.NewDirectByteBuffer(env, ptr, w * h * 4)
        check(env, "NewDirectByteBuffer")
        self:_void("capture", "iilii", slot, id, buf, w, h)
        E.DeleteLocalRef(env, buf)
    end)
end

function Bridge:free()
    if not self.object then return end
    pcall(function()
        self:_with(function(jni)
            local env = jni.env
            env[0].CallVoidMethodA(env, self.object, self.mid.closeAll, ffi.new("jvalue[1]"))
            env[0].ExceptionClear(env)
            env[0].DeleteGlobalRef(env, self.object)
            env[0].DeleteGlobalRef(env, self.class)
            env[0].DeleteGlobalRef(env, self.loader)
        end)
    end)
    self.object = nil
end

return Bridge
