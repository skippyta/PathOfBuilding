#@
---@diagnostic disable: lowercase-global
-- This wrapper allows the program to run headless on any OS (in theory)
-- It can be run using a standard lua interpreter, although LuaJIT is preferable

local function has_flag(flag)
	if type(arg) ~= "table" then return false end
	for i = 1, #arg do
		if arg[i] == flag then return true end
	end
	return false
end

local API_STDIO_MODE = os.getenv("POB_API_STDIO") == "1" or has_flag("--stdio")
_G.POB_API_STDIO_MODE = API_STDIO_MODE


local l_require = require
function require(name)
	-- Hack to stop it looking for lcurl, which we don't really need
	if name == "lcurl.safe" then
		return
	end
	return l_require(name)
end

-- Determine script directory for robust relative loading
local function get_script_dir()
  local info = debug and debug.getinfo and debug.getinfo(1, 'S')
  local src = info and info.source or ''
  if type(src) == 'string' and src:sub(1,1) == '@' then
    local path = src:sub(2)
    return (path:gsub('[^/\\]+$', '')):gsub('[ /\\]$', '')
  end
  return ''
end
local POB_SCRIPT_DIR = get_script_dir()
-- If script dir unknown (e.g., launched as 'luajit HeadlessWrapper.lua'), fall back:
if POB_SCRIPT_DIR == '' then
  -- Case 1: running inside src
  local f1 = io.open('HeadlessWrapper.lua', 'r')
  if f1 then f1:close(); POB_SCRIPT_DIR = '.' end
end
if POB_SCRIPT_DIR == '' then
  -- Case 2: running from repo root
  local f2 = io.open('src/HeadlessWrapper.lua', 'r')
  if f2 then f2:close(); POB_SCRIPT_DIR = 'src' end
end
if POB_SCRIPT_DIR ~= '' then
  _G.POB_SCRIPT_DIR = POB_SCRIPT_DIR
  local pathSegs = {}
  table.insert(pathSegs, POB_SCRIPT_DIR .. '/?.lua')
  table.insert(pathSegs, POB_SCRIPT_DIR .. '/?/init.lua')
  table.insert(pathSegs, package.path)
  package.path = table.concat(pathSegs, ';')
  -- Add runtime lua path so modules like 'xml' resolve without external LUA_PATH
  local runtimeCandidates = {
    POB_SCRIPT_DIR .. '/runtime/lua',
    POB_SCRIPT_DIR .. '/../runtime/lua',
    'runtime/lua',
    '../runtime/lua',
  }
  for _, rp in ipairs(runtimeCandidates) do
    local test = io.open(rp .. '/xml.lua', 'r')
    if test then
      test:close()
      if not string.find(package.path, rp .. '/?.lua', 1, true) then
        package.path = rp .. '/?.lua;' .. rp .. '/?/init.lua;' .. package.path
      end
      break
    end
  end
end

local function change_work_dir(path)
  local okLfs, lfs = pcall(require, 'lfs')
  if okLfs and lfs and lfs.chdir then
    return lfs.chdir(path)
  end
  local okFfi, ffi = pcall(require, 'ffi')
  if okFfi and ffi then
    if package.config:sub(1, 1) == '\\' then
      ffi.cdef('int _chdir(const char *dirname);')
      return ffi.C._chdir(path) == 0
    end
    ffi.cdef('int chdir(const char *path);')
    return ffi.C.chdir(path) == 0
  end
  return false, 'no chdir implementation is available'
end

if API_STDIO_MODE then
  -- PoB resolves modules and data relative to src. Consumers may invoke this
  -- wrapper by absolute path from the engine root, so normalize the process
  -- working directory before Launch.lua loads anything.
  if POB_SCRIPT_DIR ~= '' then
    local changed, changeErr = change_work_dir(POB_SCRIPT_DIR)
    if not changed then
      error('failed to change working directory to PoB src: ' .. tostring(changeErr))
    end
    POB_SCRIPT_DIR = '.'
    _G.POB_SCRIPT_DIR = POB_SCRIPT_DIR
    package.path = './?.lua;./?/init.lua;../runtime/lua/?.lua;../runtime/lua/?/init.lua;' .. package.path
  end
end

-- Upstream platform stubs, followed by the headless bridge IO overrides.
dofile("_SimpleGraphic.def.lua")

-- Callbacks
__callbackTable__ = { }

function runCallback(name, ...)
	if __callbackTable__[name] then
		return __callbackTable__[name](...)
	elseif __mainObject__ and __mainObject__[name] then
		return __mainObject__[name](__mainObject__, ...)
	end
end

function GetVirtualScreenSize()
	return 1920, 1080
end

-- Search Handles
local fileSearchClass = { }
fileSearchClass.__index = fileSearchClass

local function file_exists(path)
	local file = io.open(path, "rb")
	if not file then return false end
	file:close()
	return true
end

function fileSearchClass:GetFileName()
	local path = self.paths[self.index]
	return path and path:match("([^/\\]+)$") or nil
end

function fileSearchClass:GetFileModifiedTime()
	-- Source checkouts do not expose a portable stat API. Tracked compressed
	-- inputs are the canonical headless source, so all discovered files share
	-- one stable comparison value.
	return 1
end

function fileSearchClass:NextFile()
	if self.index >= #self.paths then return false end
	self.index = self.index + 1
	return true
end

function NewFileSearch(pattern)
	if type(pattern) ~= "string" then return nil end
	-- Headless mode always reads tracked compressed LUTs. It never trusts or
	-- races on generated .bin cache files left by another process.
	if API_STDIO_MODE and pattern:match("%.bin$") then return nil end
	local paths = { }
	if pattern:sub(-1) == "*" and not pattern:sub(1, -2):find("*", 1, true) then
		local prefix = pattern:sub(1, -2)
		for part = 0, 999 do
			local candidate = prefix .. tostring(part)
			if not file_exists(candidate) then break end
			table.insert(paths, candidate)
		end
	elseif not pattern:find("*", 1, true) and file_exists(pattern) then
		table.insert(paths, pattern)
	end
	if #paths == 0 then return nil end
	return setmetatable({ paths = paths, index = 1 }, fileSearchClass)
end

local zlibFfi
local zlibLibrary
local function load_zlib()
	if zlibFfi and zlibLibrary then return zlibFfi, zlibLibrary end
	local okFfi, ffi = pcall(require, "ffi")
	if not okFfi then return nil, nil end
	pcall(ffi.cdef, [[
		int uncompress(unsigned char *dest, unsigned long *destLen,
			const unsigned char *source, unsigned long sourceLen);
	]])
	for _, name in ipairs({ "z", "libz.so.1", "zlib1", "libz" }) do
		local okLibrary, library = pcall(ffi.load, name)
		if okLibrary then
			zlibFfi = ffi
			zlibLibrary = library
			return zlibFfi, zlibLibrary
		end
	end
	return nil, nil
end

function Inflate(data)
	if type(data) ~= "string" then return nil, "compressed data must be a string" end
	if #data == 0 then return "" end
	local ffi, zlib = load_zlib()
	if not ffi or not zlib then return nil, "zlib is unavailable" end
	local capacity = math.max(#data * 4, 4096)
	local maximumCapacity = 1024 * 1024 * 1024
	while capacity <= maximumCapacity do
		local output = ffi.new("unsigned char[?]", capacity)
		local outputLength = ffi.new("unsigned long[1]", capacity)
		local result = zlib.uncompress(output, outputLength, data, #data)
		if result == 0 then
			return ffi.string(output, tonumber(outputLength[0]))
		elseif result ~= -5 then
			return nil, "zlib inflate failed with code " .. tostring(result)
		end
		capacity = capacity * 2
	end
	return nil, "inflated data exceeds the headless safety limit"
end
function GetScriptPath()
	return rawget(_G, "POB_SCRIPT_DIR") or ""
end
function ConPrintf(fmt, ...)
	local message = string.format(fmt, ...)
	if API_STDIO_MODE then
		io.stderr:write(message, "\n")
	else
		print(message)
	end
end

if API_STDIO_MODE then
  -- Official distributions provide lua-utf8 as a native module. Source-only
  -- headless environments (including macOS/Linux CI) do not, so install the
  -- compatibility module only when the native implementation is unavailable.
  local hasNativeUtf8 = pcall(require, 'lua-utf8')
  if not hasNativeUtf8 then
    local fallbackPath = (POB_SCRIPT_DIR ~= '' and (POB_SCRIPT_DIR .. '/API/Utf8Fallback.lua')) or 'API/Utf8Fallback.lua'
    local fallback = dofile(fallbackPath)
    package.loaded['lua-utf8'] = fallback
  end

  -- Load Launch.lua first to initialize __mainObject__ and build system
  local launchPath = (POB_SCRIPT_DIR ~= '' and (POB_SCRIPT_DIR .. '/Launch.lua')) or 'Launch.lua'
  dofile(launchPath)

  -- Initialize the build system (same as non-STDIO mode)
  __mainObject__.continuousIntegrationMode = os.getenv("CI")
  runCallback("OnInit")
  runCallback("OnFrame") -- Need at least one frame for everything to initialise

  if __mainObject__.promptMsg then
    -- Something went wrong during startup
    io.stderr:write('[HeadlessWrapper] Error during init: ' .. tostring(__mainObject__.promptMsg) .. '\n')
    error(__mainObject__.promptMsg)
  end

  -- Set up helper functions
  function newBuild()
    __mainObject__.main:SetMode("BUILD", false, "Help, I'm stuck in Path of Building!")
    runCallback("OnFrame")
    if __mainObject__.promptMsg then return nil, tostring(__mainObject__.promptMsg) end
    return true
  end
  function loadBuildFromXML(xmlText, name)
    __mainObject__.main:SetMode("BUILD", false, name or "", xmlText)
    runCallback("OnFrame")
    if __mainObject__.promptMsg then return nil, tostring(__mainObject__.promptMsg) end
    return true
  end
  _G.newBuild = newBuild
  _G.loadBuildFromXML = loadBuildFromXML
  _G.build = __mainObject__.main.modes["BUILD"]

  -- Now start the API server
  local srvPath = (POB_SCRIPT_DIR ~= '' and (POB_SCRIPT_DIR .. '/API/Server.lua')) or 'API/Server.lua'
  dofile(srvPath)
  return
end
dofile("Launch.lua")

-- Prevents loading of ModCache
-- Allows running mod parsing related tests without pushing ModCache
-- The CI env var will be true when run from github workflows but should be false for other tools using the headless wrapper 
__mainObject__.continuousIntegrationMode = os.getenv("CI")

runCallback("OnInit")
runCallback("OnFrame") -- Need at least one frame for everything to initialise

if __mainObject__.promptMsg then
	-- Something went wrong during startup
	print(__mainObject__.promptMsg)
	io.read("*l")
	return
end

-- The build module; once a build is loaded, you can find all the good stuff in here
build = __mainObject__.main.modes["BUILD"]

-- Here's some helpful helper functions to help you get started
function newBuild()
	__mainObject__.main:SetMode("BUILD", false, "Help, I'm stuck in Path of Building!")
	runCallback("OnFrame")
end
function loadBuildFromXML(xmlText, name)
	__mainObject__.main:SetMode("BUILD", false, name or "", xmlText)
	runCallback("OnFrame")
end
function loadBuildFromJSON(characterJSON)
	__mainObject__.main:SetMode("BUILD", false, "")
	runCallback("OnFrame")
	-- characterJSON could, for example, be the response from the PoE API:
	-- https://www.pathofexile.com/developer/docs/reference#characters-get
	local dkjson = require "dkjson"
	local input = dkjson.decode(characterJSON)
	local charData = build.importTab:ImportItemsAndSkills(input)
	build.importTab:ImportPassiveTreeAndJewels(input)
	-- You now have a build without a correct main skill selected, or any configuration options set
	-- Good luck!
end
