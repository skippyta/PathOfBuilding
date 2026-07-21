-- Unicode-safe fallback for the subset of lua-utf8 used by PoB headless mode.
-- Native PoB distributions continue to use the bundled lua-utf8 module.

local M = {}

local function is_continuation(byte)
  return byte and byte >= 0x80 and byte <= 0xBF
end

local function codepoint_width(value, index)
  local first = string.byte(value, index)
  if not first or first < 0x80 then return 1 end

  local width
  if first >= 0xC2 and first <= 0xDF then
    width = 2
  elseif first >= 0xE0 and first <= 0xEF then
    width = 3
  elseif first >= 0xF0 and first <= 0xF4 then
    width = 4
  else
    return 1
  end

  if index + width - 1 > #value then return 1 end
  for offset = 1, width - 1 do
    if not is_continuation(string.byte(value, index + offset)) then
      return 1
    end
  end
  return width
end

local function boundaries(value)
  local positions = {}
  local index = 1
  while index <= #value do
    positions[#positions + 1] = index
    index = index + codepoint_width(value, index)
  end
  positions[#positions + 1] = #value + 1
  return positions
end

local function normalize_index(index, length, defaultValue)
  index = tonumber(index)
  if not index then return defaultValue end
  index = math.floor(index)
  if index < 0 then return length + index + 1 end
  return index
end

function M.len(value)
  assert(type(value) == 'string', 'bad argument #1 to len (string expected)')
  return #boundaries(value) - 1
end

function M.reverse(value)
  assert(type(value) == 'string', 'bad argument #1 to reverse (string expected)')
  local positions = boundaries(value)
  local result = {}
  for index = #positions - 1, 1, -1 do
    result[#result + 1] = string.sub(value, positions[index], positions[index + 1] - 1)
  end
  return table.concat(result)
end

function M.sub(value, first, last)
  assert(type(value) == 'string', 'bad argument #1 to sub (string expected)')
  local positions = boundaries(value)
  local length = #positions - 1
  first = normalize_index(first, length, 1)
  last = normalize_index(last, length, length)
  if first < 1 then first = 1 end
  if last > length then last = length end
  if first > last or first > length or last < 1 then return '' end
  return string.sub(value, positions[first], positions[last + 1] - 1)
end

-- PoB's patterns at these call sites target ASCII digits, punctuation, and
-- whitespace. Lua's byte-pattern engine preserves surrounding UTF-8 bytes.
M.gsub = string.gsub
M.find = string.find
M.match = string.match

function M.next(value, index, direction)
  assert(type(value) == 'string', 'bad argument #1 to next (string expected)')
  index = tonumber(index) or 0
  direction = tonumber(direction) or 1
  local positions = boundaries(value)

  if direction >= 0 then
    local remaining = math.max(1, math.floor(direction))
    for _, position in ipairs(positions) do
      if position > index then
        remaining = remaining - 1
        if remaining == 0 then return position end
      end
    end
    return #value + 1
  end

  local remaining = math.max(1, math.floor(-direction))
  for positionIndex = #positions, 1, -1 do
    local position = positions[positionIndex]
    if position < index then
      remaining = remaining - 1
      if remaining == 0 then return position end
    end
  end
  return 0
end

return M
