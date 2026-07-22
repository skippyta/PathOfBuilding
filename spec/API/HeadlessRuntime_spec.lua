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
      BrutalRestraint = 3390452,
      ElegantHubris = 3571252,
      GloriousVanity = 51484784,
      HeroicTragedy = 3571252,
      LethalPride = 3616452,
      MilitantFaith = 3616452,
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

  it('fails safely for malformed compressed data', function()
    local inflated, inflateError = Inflate('not-zlib')
    assert.is_nil(inflated)
    assert.matches('zlib inflate failed', inflateError)
  end)
end)
