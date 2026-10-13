package.path = "lua/?.lua;lua/?/init.lua;" .. package.path
local starts, stopped = {}, false
local result = { exit_code = 0 }
local runtime = { bin = "node", kind = "node", version = "22.19.0" }
maki = {
  env = { config_dir = function() return "/wrong-config" end },
  pack = { get = function() return {
    { spec = { src = "https://github.com/MrBanh/maki-freeflow" }, path = "/managed/revision" },
  } end },
  async = { sleep = function() end },
  fn = {
    jobstart = function(argv, opts) starts[#starts + 1] = { argv = argv, opts = opts }; return #starts end,
    jobwait = function() return result end,
    jobstop = function() stopped = true end,
    jobfind = function() return nil end,
  },
  log = { info = function() end },
}
local daemon = require("freeflow.daemon")
assert(daemon.vendor_dir() == "/managed/revision/vendor")
assert(daemon.ensure_dependencies(runtime))
assert(starts[1].argv[2] == "/managed/revision/vendor/maki-setup.mjs")
assert(daemon.ensure_dependencies(runtime) and #starts == 1, "setup must be cached")

daemon.set_vendor_dir("/custom/vendor")
result = { exit_code = 1, stderr_lines = { "Cannot install: offline", "Run npm ci in /custom/vendor" } }
local ok, err = daemon.ensure_dependencies(runtime)
assert(not ok and err:find("offline") and err:find("/custom/vendor"))
result = nil
ok, err = daemon.ensure_dependencies(runtime)
assert(not ok and err:find("timed out") and stopped)
result = { exit_code = 0 }
assert(daemon.ensure_dependencies(runtime), "failed setup must be retryable")

-- A child that fails before readiness reports stderr instead of a generic URL error.
daemon.node_runtime = function() return runtime end
daemon.probe_alive = function() return false end
result = { exit_code = 1, stderr = "Error: daemon import failed" }
ok, err = daemon.ensure("test-client")
assert(not ok and err:find("daemon import failed"))
assert(starts[#starts].opts.stderr ~= false, "startup stderr must be captured")

-- Source resolution also supports a hand-installed package outside user config.
local original_debug = debug
debug = { info = function() return "@/hand-installed/maki-freeflow/lua/freeflow/daemon.lua" end }
package.loaded["freeflow.daemon"] = nil
daemon = require("freeflow.daemon")
assert(daemon.vendor_dir() == "/hand-installed/maki-freeflow/vendor")
debug = original_debug
print("setup Lua checks passed")
