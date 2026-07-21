local probe = io.open('API/Utf8Fallback.lua', 'r')
local fallbackPath = probe and 'API/Utf8Fallback.lua' or 'src/API/Utf8Fallback.lua'
if probe then probe:close() end
local utf8 = dofile(fallbackPath)

describe('API UTF-8 fallback', function()
  it('preserves complete codepoints while reversing and slicing', function()
    assert.are.equal(4, utf8.len('Aé界🙂'))
    assert.are.equal('🙂界éA', utf8.reverse('Aé界🙂'))
    assert.are.equal('é界', utf8.sub('Aé界🙂', 2, 3))
    assert.are.equal('界🙂', utf8.sub('Aé界🙂', -2))
  end)

  it('moves across byte boundaries without splitting codepoints', function()
    assert.are.equal(3, utf8.next('éA', 1, 1))
    assert.are.equal(3, utf8.next('éA', 2, 1))
    assert.are.equal(1, utf8.next('éA', 3, -1))
  end)
end)
