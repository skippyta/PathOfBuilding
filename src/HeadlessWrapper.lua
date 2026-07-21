#@
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


-- Callbacks
local callbackTable = { }
local mainObject
function runCallback(name, ...)
	if callbackTable[name] then
		return callbackTable[name](...)
	elseif mainObject and mainObject[name] then
		return mainObject[name](mainObject, ...)
	end
end
function SetCallback(name, func)
	callbackTable[name] = func
end
function GetCallback(name)
	return callbackTable[name]
end
function SetMainObject(obj)
	mainObject = obj
end

-- Image Handles
local imageHandleClass = { }
imageHandleClass.__index = imageHandleClass
function NewImageHandle()
	return setmetatable({ }, imageHandleClass)
end
function imageHandleClass:Load(fileName, ...)
	self.valid = true
end
function imageHandleClass:Unload()
	self.valid = false
end
function imageHandleClass:IsValid()
	return self.valid
end
function imageHandleClass:SetLoadingPriority(pri) end
function imageHandleClass:ImageSize()
	return 1, 1
end

-- Rendering
function RenderInit(flag, ...) end
function GetScreenSize()
	return 1920, 1080
end
function GetScreenScale()
	return 1
end
function GetVirtualScreenSize()
	return GetScreenSize()
end
function GetDPIScaleOverridePercent()
	return 1
end
function SetDPIScaleOverridePercent(scale) end
function SetClearColor(r, g, b, a) end
function SetDrawLayer(layer, subLayer) end
function SetViewport(x, y, width, height) end
function SetDrawColor(r, g, b, a) end
function DrawImage(imgHandle, left, top, width, height, tcLeft, tcTop, tcRight, tcBottom) end
function DrawImageQuad(imageHandle, x1, y1, x2, y2, x3, y3, x4, y4, s1, t1, s2, t2, s3, t3, s4, t4) end
function DrawString(left, top, align, height, font, text) end
function DrawStringWidth(height, font, text)
	return 1
end
function DrawStringCursorIndex(height, font, text, cursorX, cursorY)
	return 0
end
function StripEscapes(text)
	return text:gsub("%^%d",""):gsub("%^x%x%x%x%x%x%x","")
end
function GetAsyncCount()
	return 0
end

-- Search Handles
function NewFileSearch() end

-- General Functions
function SetWindowTitle(title) end
function GetCursorPos()
	return 0, 0
end
function SetCursorPos(x, y) end
function ShowCursor(doShow) end
function IsKeyDown(keyName) end
function Copy(text) end
function Paste() end
function Deflate(data)
	-- TODO: Might need this
	return ""
end
function Inflate(data)
	-- TODO: And this
	return ""
end
function GetTime()
	return 0
end
function GetScriptPath()
	return ""
end
function GetRuntimePath()
	return ""
end
function GetUserPath()
	return ""
end
function MakeDir(path) end
function RemoveDir(path) end
function SetWorkDir(path) end
function GetWorkDir()
	return ""
end
function LaunchSubScript(scriptText, funcList, subList, ...) end
function AbortSubScript(ssID) end
function IsSubScriptRunning(ssID) end
function LoadModule(fileName, ...)
	if not fileName:match("%.lua") then
		fileName = fileName .. ".lua"
	end
	local func, err = loadfile(fileName)
	if func then
		return func(...)
	else
		error("LoadModule() error loading '"..fileName.."': "..err)
	end
end
function PLoadModule(fileName, ...)
	if not fileName:match("%.lua") then
		fileName = fileName .. ".lua"
	end
	local func, err = loadfile(fileName)
	if func then
		return PCall(func, ...)
	else
		error("PLoadModule() error loading '"..fileName.."': "..err)
	end
end
function PCall(func, ...)
	local ret = { pcall(func, ...) }
	if ret[1] then
		table.remove(ret, 1)
		return nil, unpack(ret)
	else
		return ret[2]
	end
end
function ConPrintf(fmt, ...)
	local message = string.format(fmt, ...)
	if API_STDIO_MODE then
		io.stderr:write(message, "\n")
	else
		print(message)
	end
end
function ConPrintTable(tbl, noRecurse) end
function ConExecute(cmd) end
function ConClear() end
function SpawnProcess(cmdName, args) end
function OpenURL(url) end
function SetProfiling(isEnabled) end
function Restart() end
function Exit() end
function TakeScreenshot() end

---@return string? provider
---@return string? version
---@return number? status
function GetCloudProvider(fullPath)
	return nil, nil, nil
end

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

-- If requested, start the stdio server immediately and exit
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
  -- Official distributions provide lua-utf8 as a native module. Source-only
  -- headless environments (including macOS/Linux CI) do not, so install the
  -- compatibility module only when the native implementation is unavailable.
  local hasNativeUtf8 = pcall(require, 'lua-utf8')
  if not hasNativeUtf8 then
    local fallbackPath = (POB_SCRIPT_DIR ~= '' and (POB_SCRIPT_DIR .. '/API/Utf8Fallback.lua')) or 'API/Utf8Fallback.lua'
    local fallback = dofile(fallbackPath)
    package.loaded['lua-utf8'] = fallback
  end

  -- Load Launch.lua first to initialize mainObject and build system
  local launchPath = (POB_SCRIPT_DIR ~= '' and (POB_SCRIPT_DIR .. '/Launch.lua')) or 'Launch.lua'
  dofile(launchPath)

  -- Initialize the build system (same as non-STDIO mode)
  mainObject.continuousIntegrationMode = os.getenv("CI")
  runCallback("OnInit")
  runCallback("OnFrame") -- Need at least one frame for everything to initialise

  if mainObject.promptMsg then
    -- Something went wrong during startup
    io.stderr:write('[HeadlessWrapper] Error during init: ' .. tostring(mainObject.promptMsg) .. '\n')
    error(mainObject.promptMsg)
  end

  -- Set up helper functions
  function newBuild()
    mainObject.main:SetMode("BUILD", false, "Help, I'm stuck in Path of Building!")
    runCallback("OnFrame")
    if mainObject.promptMsg then return nil, tostring(mainObject.promptMsg) end
    return true
  end
  function loadBuildFromXML(xmlText, name)
    mainObject.main:SetMode("BUILD", false, name or "", xmlText)
    runCallback("OnFrame")
    if mainObject.promptMsg then return nil, tostring(mainObject.promptMsg) end
    return true
  end
  _G.newBuild = newBuild
  _G.loadBuildFromXML = loadBuildFromXML
  _G.build = mainObject.main.modes["BUILD"]

  -- Now start the API server
  local srvPath = (POB_SCRIPT_DIR ~= '' and (POB_SCRIPT_DIR .. '/API/Server.lua')) or 'API/Server.lua'
  dofile(srvPath)
  return
end
dofile("Launch.lua")

-- Prevents loading of ModCache
-- Allows running mod parsing related tests without pushing ModCache
-- The CI env var will be true when run from github workflows but should be false for other tools using the headless wrapper
mainObject.continuousIntegrationMode = os.getenv("CI")

runCallback("OnInit")
runCallback("OnFrame") -- Need at least one frame for everything to initialise

if mainObject.promptMsg then
	-- Something went wrong during startup
	print(mainObject.promptMsg)
	io.read("*l")
	return
end

-- The build module; once a build is loaded, you can find all the good stuff in here
build = mainObject.main.modes["BUILD"]

-- Here's some helpful helper functions to help you get started
function newBuild()
	mainObject.main:SetMode("BUILD", false, "Help, I'm stuck in Path of Building!")
	runCallback("OnFrame")
end
function loadBuildFromXML(xmlText, name)
	mainObject.main:SetMode("BUILD", false, name or "", xmlText)
	runCallback("OnFrame")
end
function loadBuildFromJSON(characterJSON)
	mainObject.main:SetMode("BUILD", false, "")
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
