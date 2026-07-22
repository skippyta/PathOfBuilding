local json_ok, json = pcall(require, 'dkjson')
if not json_ok then
  local ok2, mod = pcall(dofile, '../runtime/lua/dkjson.lua')
  if ok2 then json = mod else error('dkjson not found for tests') end
end

local function run_stdio_session(lines, fromEngineRoot)
  local tmp_in = os.tmpname()
  local f = assert(io.open(tmp_in, 'w'))
  for _, ln in ipairs(lines) do
    f:write(ln, "\n")
  end
  f:close()

  local cmd
  if fromEngineRoot then
    cmd = string.format("cd .. && env POB_API_STDIO=1 luajit src/HeadlessWrapper.lua < %q", tmp_in)
  else
    cmd = string.format("env POB_API_STDIO=1 luajit HeadlessWrapper.lua < %q", tmp_in)
  end
  local p = assert(io.popen(cmd, 'r'))
  local out = p:read('*a') or ''
  p:close()
  os.remove(tmp_in)

  local objs = {}
  for line in out:gmatch("[^\r\n]+") do
    local ok, obj = pcall(json.decode, line)
    assert.is_true(ok, 'stdout contained non-JSON protocol data: ' .. line)
    assert.is_table(obj, 'stdout response was not an object')
    table.insert(objs, obj)
  end
  return out, objs
end

describe('Stdio API', function()
  it('responds to ready, ping, version and quit', function()
    local _, objs = run_stdio_session({
      '{"action":"ping"}',
      '{"action":"version"}',
      '{"action":"quit"}',
    })
    assert.is_true(#objs >= 3)
    local idxReady, idxPing, idxVersion, idxQuit
    for i, o in ipairs(objs) do
      if o.ready then idxReady = idxReady or i end
      if o.pong then idxPing = idxPing or i end
      if o.version and not o.ready then idxVersion = idxVersion or i end
      if o.quit then idxQuit = idxQuit or i end
    end
    assert.is_truthy(idxReady, 'missing ready response')
    assert.is_truthy(idxPing, 'missing ping response')
    assert.is_truthy(idxVersion, 'missing version response')
    assert.is_truthy(idxQuit, 'missing quit response')
    assert.is_true(idxReady < idxPing)
    assert.is_true(idxPing < idxVersion)
    assert.is_true(idxVersion < idxQuit)
    assert.are.equal(true, objs[idxReady].ok)
    assert.are.equal(true, objs[idxPing].ok)
    assert.are.equal(true, objs[idxQuit].ok)
    assert.is_table(objs[idxVersion].version)
    assert.is_not_nil(objs[idxVersion].version.number)
    assert.is_not_nil(objs[idxVersion].version.branch)
    assert.is_not_nil(objs[idxVersion].version.platform)
    assert.are.equal('2.2.0', objs[idxReady].version.apiVersion)
    assert.are.equal('2.2.0', objs[idxReady].version.protocolVersion)
    assert.are.equal('78951a2e7d23bc0bb78e4a2ff777b82e1e54dc1f', objs[idxReady].version.engineBaseRevision)
    assert.is_table(objs[idxReady].version.capabilities)
    local capabilities = {}
    for _, capability in ipairs(objs[idxReady].version.capabilities) do
      capabilities[capability] = true
    end
    assert.is_true(capabilities.set_tree)
    assert.is_true(capabilities.get_mastery_options)
    assert.is_true(capabilities.create_spec)
    assert.is_true(capabilities.set_gem_enabled)
  end)

  it('starts by absolute wrapper path from the engine root with JSON-only stdout', function()
    local _, objs = run_stdio_session({
      '{"action":"ping"}',
      '{"action":"quit"}',
    }, true)
    assert.are.equal(true, objs[1].ready)
    assert.are.equal(true, objs[2].pong)
    assert.are.equal(true, objs[3].quit)
  end)

  it('returns error on unknown action', function()
    local _, objs = run_stdio_session({
      '{"action":"does_not_exist"}',
      '{"action":"quit"}',
    })
    local sawError = false
    for _, o in ipairs(objs) do
      if o.ok == false and o.errorCode == 'UNKNOWN_ACTION' and o.error and o.error:match('unknown action') then
        sawError = true
        break
      end
    end
    assert.is_true(sawError)
  end)

  it('returns exact typed protocol errors for malformed and non-object input', function()
    local _, objs = run_stdio_session({
      'not-json',
      '"valid json, wrong shape"',
      '{}',
      '{"action":"quit"}',
    })
    assert.are.equal('INVALID_JSON', objs[2].errorCode)
    assert.are.equal('INVALID_JSON', objs[3].errorCode)
    assert.are.equal('UNKNOWN_ACTION', objs[4].errorCode)
  end)
end)
