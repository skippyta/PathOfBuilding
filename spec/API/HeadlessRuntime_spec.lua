describe('Headless runtime data support', function()
  it('enumerates split Timeless Jewel inputs in numeric order', function()
    local search = assert(NewFileSearch('Data/TimelessJewelData/GloriousVanity.zip.part*'))
    local names = {}
    repeat
      table.insert(names, search:GetFileName())
    until not search:NextFile()

    assert.same({
      'GloriousVanity.zip.part0',
      'GloriousVanity.zip.part1',
      'GloriousVanity.zip.part2',
      'GloriousVanity.zip.part3',
      'GloriousVanity.zip.part4',
    }, names)
  end)

  it('inflates every tracked Timeless Jewel data set exactly', function()
    local expected = {
      BrutalRestraint = 3405454,
      ElegantHubris = 3587054,
      GloriousVanity = 51651890,
      HeroicTragedy = 3587054,
      LethalPride = 3632454,
      MilitantFaith = 3632454,
    }
    for name, expectedLength in pairs(expected) do
      local compressed
      if name == 'GloriousVanity' then
        local parts = {}
        for part = 0, 4 do
          local file = assert(io.open('Data/TimelessJewelData/' .. name .. '.zip.part' .. part, 'rb'))
          table.insert(parts, file:read('*a'))
          file:close()
        end
        compressed = table.concat(parts)
      else
        local file = assert(io.open('Data/TimelessJewelData/' .. name .. '.zip', 'rb'))
        compressed = file:read('*a')
        file:close()
      end
      local inflated, inflateError = Inflate(compressed)
      assert.is_nil(inflateError)
      assert.are.equal(expectedLength, #inflated)
    end
  end)

  it('never accesses shared binary caches in stdio mode', function()
    local savedMode, savedOpen = _G.POB_API_STDIO_MODE, io.open
    _G.POB_API_STDIO_MODE = true
    local binAccesses = {}
    io.open = function(path, mode)
      if path:match('%.bin$') then table.insert(binAccesses, {path, mode}) end
      return savedOpen(path, mode)
    end
    local ok, result = pcall(function()
      return LoadModule('Modules/DataJewelFileLoader')('LethalPride', true)
    end)
    io.open, _G.POB_API_STDIO_MODE = savedOpen, savedMode
    assert.is_true(ok)
    assert.is_string(result)
    assert.same({}, binAccesses)
  end)

  it('fails safely for malformed compressed data', function()
    local inflated, inflateError = Inflate('not-zlib')
    assert.is_nil(inflated)
    assert.matches('zlib inflate failed', inflateError)
  end)
end)
