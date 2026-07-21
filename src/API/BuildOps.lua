-- API/BuildOps.lua
-- Thin wrappers around PoB headless objects for programmatic operations

local M = {}

-- Constants
local MIN_PLAYER_LEVEL = 1
local MAX_PLAYER_LEVEL = 100
local NUM_FLASK_SLOTS = 5
local MAX_ITEM_TEXT_LENGTH = 10240  -- 10KB

local function normalize_node_ids(values, fieldName)
  if values == nil then
    return {}
  end
  if type(values) ~= 'table' then
    return nil, fieldName .. ' must be an array'
  end
  local valueMeta = getmetatable(values)
  if valueMeta and valueMeta.__jsontype == 'object' then
    return nil, fieldName .. ' must be an array'
  end
  local normalized = {}
  local count = 0
  for key in pairs(values) do
    if type(key) ~= 'number' or key < 1 or key ~= math.floor(key) then
      return nil, fieldName .. ' must be an array'
    end
    count = count + 1
  end
  for index = 1, count do
    local value = values[index]
    if value == nil then
      return nil, fieldName .. ' must not be sparse'
    end
    local nodeId = tonumber(value)
    if not nodeId or nodeId <= 0 or nodeId ~= math.floor(nodeId) then
      return nil, string.format('%s[%d] must be a positive integer', fieldName, index)
    end
    normalized[#normalized + 1] = nodeId
  end
  return normalized
end

local function normalize_mastery_effects(values)
  if values == nil then
    return {}
  end
  if type(values) ~= 'table' then
    return nil, 'masteryEffects must be an object'
  end
  local normalized = {}
  for nodeId, effectId in pairs(values) do
    local numericNodeId = tonumber(nodeId)
    local numericEffectId = tonumber(effectId)
    if not numericNodeId or numericNodeId <= 0 or numericNodeId ~= math.floor(numericNodeId) then
      return nil, 'masteryEffects contains an invalid node id'
    end
    if not numericEffectId or numericEffectId <= 0 or numericEffectId ~= math.floor(numericEffectId) then
      return nil, string.format('masteryEffects[%s] must be a positive integer', tostring(nodeId))
    end
    normalized[numericNodeId] = numericEffectId
  end
  return normalized
end

local function scalar_output_snapshot(output)
  local snapshot = {}
  for key, value in pairs(output or {}) do
    local valueType = type(value)
    if type(key) == 'string' and (valueType == 'number' or valueType == 'string' or valueType == 'boolean') then
      snapshot[key] = value
    end
  end
  return snapshot
end

-- Ensure outputs are (re)built and return the main output table safely
function M.get_main_output()
  if not build or not build.calcsTab then
    return nil, "build not initialized"
  end
  if build.calcsTab.BuildOutput then
    build.calcsTab:BuildOutput()
  end
  local output = build.calcsTab and build.calcsTab.mainOutput or nil
  if not output then
    return nil, "no output available"
  end
  return output
end

-- Export a subset of useful stats from main output
-- If fields is provided, only export those keys (when present)
function M.export_stats(fields)
  local output, err = M.get_main_output()
  if not output then
    return nil, err
  end
  local wanted = fields or {
    "Life", "EnergyShield", "Armour", "Evasion",
    "FireResist", "ColdResist", "LightningResist", "ChaosResist",
    "BlockChance", "SpellBlockChance",
    "LifeRegen", "Mana", "ManaRegen",
    "Ward", "DodgeChance", "SpellDodgeChance",
  }
  local result = {}
  for _, k in ipairs(wanted) do
    if type(output[k]) ~= 'nil' then
      result[k] = output[k]
    end
  end
  -- include some metadata if available
  result._meta = result._meta or {}
  if build and build.targetVersion then
    result._meta.treeVersion = tostring(build.targetVersion)
  end
  if build and build.characterLevel then
    result._meta.level = tonumber(build.characterLevel)
  end
  if build and build.buildName then
    result._meta.buildName = tostring(build.buildName)
  end
  return result
end

-- Read current tree allocation and metadata
function M.get_tree()
  if not build or not build.spec then
    return nil, "build/spec not initialized"
  end
  local spec = build.spec
  local out = {
    treeVersion = spec.treeVersion,
    classId = tonumber(spec.curClassId) or 0,
    ascendClassId = tonumber(spec.curAscendClassId) or 0,
    secondaryAscendClassId = tonumber(spec.curSecondaryAscendClassId or 0) or 0,
    nodes = {},
    masteryEffects = {},
  }
  for id, _ in pairs(spec.allocNodes or {}) do
    table.insert(out.nodes, id)
  end
  for mastery, effect in pairs(spec.masterySelections or {}) do
    out.masteryEffects[mastery] = effect
  end
  table.sort(out.nodes)
  return out
end

-- Set tree allocation from parameters
-- params: { classId, ascendClassId, secondaryAscendClassId?, nodes:[int], masteryEffects?:{[id]=effect}, treeVersion? }
function M.set_tree(params)
  if not build or not build.spec then
    return nil, "build/spec not initialized"
  end
  if type(params) ~= 'table' then
    return nil, "invalid params"
  end
  local classId = tonumber(params.classId)
  local ascendId = tonumber(params.ascendClassId or 0)
  local secondaryId = tonumber(params.secondaryAscendClassId or 0)
  if not classId or classId ~= math.floor(classId) then return nil, 'invalid classId' end
  if not ascendId or ascendId ~= math.floor(ascendId) then return nil, 'invalid ascendClassId' end
  if not secondaryId or secondaryId ~= math.floor(secondaryId) then return nil, 'invalid secondaryAscendClassId' end
  local nodes, nodesErr = normalize_node_ids(params.nodes, 'nodes')
  if not nodes then return nil, nodesErr end
  local mastery, masteryErr = normalize_mastery_effects(params.masteryEffects)
  if not mastery then return nil, masteryErr end
  local treeVersion = params.treeVersion or build.spec.treeVersion
  if type(treeVersion) ~= 'string' or not treeVersions[treeVersion] or not main.tree[treeVersion] then
    return nil, 'invalid treeVersion'
  end
  local tree = main.tree[treeVersion]
  local class = tree.classes and tree.classes[classId]
  if not class then return nil, 'unknown classId' end
  if ascendId < 0 or not class.classes or not class.classes[ascendId] then
    return nil, 'unknown ascendClassId'
  end
  if secondaryId < 0 or (secondaryId ~= 0 and tree.alternate_ascendancies and not tree.alternate_ascendancies[secondaryId]) then
    return nil, 'unknown secondaryAscendClassId'
  end
  local knownNodes = tree.nodes or {}
  for _, nodeId in ipairs(nodes) do
    if not knownNodes[nodeId] and not build.spec.nodes[nodeId] then
      return nil, 'unknown node id: ' .. tostring(nodeId)
    end
  end
  for nodeId, effectId in pairs(mastery) do
    local node = knownNodes[nodeId] or build.spec.nodes[nodeId]
    local effect = tree.masteryEffects and tree.masteryEffects[effectId]
    if not node or node.type ~= 'Mastery' or not effect then
      return nil, 'invalid mastery selection for node ' .. tostring(nodeId)
    end
  end
  -- Import (resets nodes internally and rebuilds)
  build.spec:ImportFromNodeList(nil, classId, ascendId, secondaryId, nodes, {}, mastery, treeVersion)
  -- Rebuild calcs to reflect changes
  M.get_main_output()
  return true
end

-- Export full build XML
function M.export_build_xml()
  if not build or not build.SaveDB then
    return nil, 'build not initialized'
  end
  local xml = build:SaveDB('api-export')
  if not xml then return nil, 'failed to compose xml' end
  return xml
end

-- Set player level and rebuild
function M.set_level(level)
  if not build or not build.configTab then
    return nil, 'build/config not initialized'
  end
  local lvl = tonumber(level)
  if not lvl or lvl < MIN_PLAYER_LEVEL or lvl > MAX_PLAYER_LEVEL then
    return nil, string.format('invalid level (must be %d-%d)', MIN_PLAYER_LEVEL, MAX_PLAYER_LEVEL)
  end
  build.characterLevel = lvl
  build.characterLevelAutoMode = false
  if build.configTab and build.configTab.BuildModList then
    build.configTab:BuildModList()
  end
  M.get_main_output()
  return true
end

-- Basic build info
function M.get_build_info()
  if not build then return nil, 'build not initialized' end
  local info = {
    name = build.buildName,
    level = build.characterLevel,
    className = build and build.buildClassName or (build.Build and build.Build.className) or nil,
    ascendClassName = build and build.buildAscendName or (build.Build and build.Build.ascendClassName) or nil,
    treeVersion = build.targetVersion or (build.spec and build.spec.treeVersion) or nil,
  }
  return info
end

-- Update tree by delta lists
function M.update_tree_delta(params)
  if not build or not build.spec then return nil, 'build/spec not initialized' end
  if params == nil then params = {} end
  if type(params) ~= 'table' then return nil, 'invalid params' end
  local current, err = M.get_tree()
  if not current then return nil, err end
  local set = {}
  for _, id in ipairs(current.nodes) do set[id] = true end
  local removeNodes, removeErr = normalize_node_ids(params.removeNodes, 'removeNodes')
  if not removeNodes then return nil, removeErr end
  local addNodes, addErr = normalize_node_ids(params.addNodes, 'addNodes')
  if not addNodes then return nil, addErr end
  for _, id in ipairs(removeNodes) do set[id] = nil end
  for _, id in ipairs(addNodes) do set[id] = true end
  local nodes = {}
  for id,_ in pairs(set) do table.insert(nodes, id) end
  table.sort(nodes)
  local mastery = current.masteryEffects or {}
  local classId = params.classId or current.classId or 0
  local ascendId = params.ascendClassId or current.ascendClassId or 0
  local secId = params.secondaryAscendClassId or current.secondaryAscendClassId or 0
  local tv = params.treeVersion or current.treeVersion
  return M.set_tree({
    classId = classId,
    ascendClassId = ascendId,
    secondaryAscendClassId = secId,
    nodes = nodes,
    masteryEffects = mastery,
    treeVersion = tv,
  })
end


-- Calculate what-if scenario without persisting changes
-- params: { addNodes?: number[], removeNodes?: number[], useFullDPS?: boolean }
function M.calc_with(params)
  if not build or not build.calcsTab then return nil, 'build not initialized' end
  params = params or {}
  local override = {}
  if params and type(params.addNodes) == 'table' then
    override.addNodes = {}
    for _, id in ipairs(params.addNodes) do
      local n = build.spec and build.spec.nodes and build.spec.nodes[tonumber(id)]
      if n then override.addNodes[n] = true end
    end
  end
  if params and type(params.removeNodes) == 'table' then
    override.removeNodes = {}
    for _, id in ipairs(params.removeNodes) do
      local n = build.spec and build.spec.nodes and build.spec.nodes[tonumber(id)]
      if n then override.removeNodes[n] = true end
    end
  end

  -- The misc calculator has no mastery override. Apply the requested mastery
  -- selection only for the duration of this calculation and restore it even
  -- when PoB raises, so what-if requests never mutate the canonical build.
  local originalMastery
  local masteryNodeState = {}
  local didOverrideMastery = false
  if type(params.masteryEffects) == 'table' and build.spec then
    local simulated, masteryErr = normalize_mastery_effects(params.masteryEffects)
    if not simulated then return nil, masteryErr end
    originalMastery = build.spec.masterySelections
    local combined = copyTable(originalMastery or {}, true)
    for nodeId, effectId in pairs(simulated) do
      local node = build.spec.allocNodes and build.spec.allocNodes[nodeId]
      local effect = build.spec.tree.masteryEffects and build.spec.tree.masteryEffects[effectId]
      if not node or node.type ~= 'Mastery' or not effect then
        return nil, 'invalid mastery selection for node ' .. tostring(nodeId)
      end
      masteryNodeState[nodeId] = {
        sd = node.sd,
        allMasteryOptions = node.allMasteryOptions,
        reminderText = node.reminderText,
      }
      node.sd = effect.sd
      node.allMasteryOptions = false
      node.reminderText = { 'Simulated mastery selection' }
      build.spec.tree:ProcessStats(node)
      combined[nodeId] = effectId
    end
    build.spec.masterySelections = combined
    didOverrideMastery = true
  end

  -- Mastery stats must be installed before the calculator is created, because
  -- GetMiscCalculator snapshots the active tree's modifier state.
  local ok, out, baseOut = pcall(function()
    local calcFunc, baseline = build.calcsTab:GetMiscCalculator()
    return calcFunc(override, params and params.useFullDPS), baseline
  end)
  if didOverrideMastery then
    build.spec.masterySelections = originalMastery
    for nodeId, state in pairs(masteryNodeState) do
      local node = build.spec.nodes[nodeId]
      if node then
        node.sd = state.sd
        node.allMasteryOptions = state.allMasteryOptions
        node.reminderText = state.reminderText
        build.spec.tree:ProcessStats(node)
      end
    end
  end
  if not ok then
    return nil, tostring(out)
  end
  return scalar_output_snapshot(out), scalar_output_snapshot(baseOut)
end


-- Get basic config values
function M.get_config()
  if not build or not build.configTab then return nil, 'build/config not initialized' end
  local cfg = {
    bandit = build.configTab.input and build.configTab.input.bandit or build.bandit,
    pantheonMajorGod = build.configTab.input and build.configTab.input.pantheonMajorGod or build.pantheonMajorGod,
    pantheonMinorGod = build.configTab.input and build.configTab.input.pantheonMinorGod or build.pantheonMinorGod,
    enemyLevel = build.configTab.enemyLevel,
  }
  return cfg
end

-- Set selected config values and rebuild
function M.set_config(params)
  if not build or not build.configTab then return nil, 'build/config not initialized' end
  if type(params) ~= 'table' then return nil, 'invalid params' end
  local input = build.configTab.input or {}
  build.configTab.input = input
  local changed = false
  if params.bandit ~= nil then input.bandit = tostring(params.bandit); changed = true end
  if params.pantheonMajorGod ~= nil then input.pantheonMajorGod = tostring(params.pantheonMajorGod); changed = true end
  if params.pantheonMinorGod ~= nil then input.pantheonMinorGod = tostring(params.pantheonMinorGod); changed = true end
  if params.enemyLevel ~= nil then build.configTab.enemyLevel = tonumber(params.enemyLevel) or build.configTab.enemyLevel; changed = true end
  if changed and build.configTab.BuildModList then build.configTab:BuildModList() end
  M.get_main_output()
  return true
end


-- Skills API
function M.get_skills()
  if not build or not build.skillsTab or not build.calcsTab then return nil, 'skills not initialized' end
  local groups = {}
  for idx, g in ipairs(build.skillsTab.socketGroupList or {}) do
    local names = {}
    if g.displaySkillList then
      for _, eff in ipairs(g.displaySkillList) do
        if eff and eff.activeEffect and eff.activeEffect.grantedEffect then
          table.insert(names, eff.activeEffect.grantedEffect.name)
        end
      end
    end
    table.insert(groups, {
      index = idx,
      label = g.label,
      slot = g.slot,
      enabled = g.enabled,
      includeInFullDPS = g.includeInFullDPS,
      mainActiveSkill = g.mainActiveSkill,
      skills = names,
    })
  end
  local result = {
    mainSocketGroup = build.mainSocketGroup,
    calcsSkillNumber = build.calcsTab.input and build.calcsTab.input.skill_number or nil,
    groups = groups,
  }
  return result
end

function M.set_main_selection(params)
  if not build or not build.skillsTab or not build.calcsTab then return nil, 'skills not initialized' end
  if type(params) ~= 'table' then return nil, 'invalid params' end
  if params.mainSocketGroup ~= nil then
    build.mainSocketGroup = tonumber(params.mainSocketGroup) or build.mainSocketGroup
  end
  local g = build.skillsTab.socketGroupList[build.mainSocketGroup]
  if not g then return nil, 'invalid mainSocketGroup' end
  if params.mainActiveSkill ~= nil then
    g.mainActiveSkill = tonumber(params.mainActiveSkill) or g.mainActiveSkill
  end
  if params.skillPart ~= nil then
    local idx = g.mainActiveSkill or 1
    local src = g.displaySkillList and g.displaySkillList[idx] and g.displaySkillList[idx].activeEffect and g.displaySkillList[idx].activeEffect.srcInstance
    if src then src.skillPart = tonumber(params.skillPart) end
  end
  -- Keep calcsTab in sync: use active group index
  build.calcsTab.input.skill_number = build.mainSocketGroup
  M.get_main_output()
  return true
end

-- Items API
function M.add_item_text(params)
  if not build or not build.itemsTab then return nil, 'items not initialized' end
  if type(params) ~= 'table' or type(params.text) ~= 'string' then return nil, 'missing text' end

  -- Validate input to prevent potential issues
  if #params.text == 0 then return nil, 'item text cannot be empty' end
  if #params.text > MAX_ITEM_TEXT_LENGTH then
    return nil, string.format('item text too long (max %d bytes)', MAX_ITEM_TEXT_LENGTH)
  end

  -- Use pcall to safely handle item creation
  local ok, item = pcall(new, 'Item', params.text)
  if not ok then return nil, 'invalid item text: ' .. tostring(item) end
  if not item or not item.baseName then return nil, 'failed to parse item' end

  item:NormaliseQuality()
  local requestedSlot
  if params.slotName then
    requestedSlot = tostring(params.slotName)
    if not build.itemsTab.slots[requestedSlot] then return nil, 'unknown slotName' end
    if not build.itemsTab:IsItemValidForSlot(item, requestedSlot) then
      return nil, 'item is not valid for slot ' .. requestedSlot
    end
  end
  build.itemsTab:AddItem(item, params.noAutoEquip == true or requestedSlot ~= nil)
  if requestedSlot then
    build.itemsTab.slots[requestedSlot]:SetSelItemId(item.id)
    build.itemsTab:PopulateSlots()
  end
  build.itemsTab:AddUndoState()
  build.buildFlag = true
  M.get_main_output()
  return { id = item.id, name = item.name, slot = requestedSlot or item:GetPrimarySlot() }
end

function M.set_flask_active(params)
  if not build or not build.itemsTab then return nil, 'items not initialized' end
  if type(params) ~= 'table' then return nil, 'invalid params' end
  local idx = tonumber(params.index)
  local active = params.active == true
  if not idx or idx < 1 or idx > NUM_FLASK_SLOTS then
    return nil, string.format('invalid flask index (must be 1-%d)', NUM_FLASK_SLOTS)
  end
  local slotName = 'Flask ' .. tostring(idx)
  if not build.itemsTab.activeItemSet or not build.itemsTab.activeItemSet[slotName] then return nil, 'slot not found' end
  build.itemsTab.activeItemSet[slotName].active = active
  build.itemsTab.slots[slotName].active = active
  if build.itemsTab.slots[slotName].controls.activate then
    build.itemsTab.slots[slotName].controls.activate.state = active
  end
  build.itemsTab:AddUndoState()
  build.buildFlag = true
  M.get_main_output()
  return true
end


-- Get equipped items summary
function M.get_items()
  if not build or not build.itemsTab then return nil, 'items not initialized' end
  local itemsTab = build.itemsTab
  local result = { }
  -- Prefer orderedSlots for deterministic order
  local ordered = itemsTab.orderedSlots or {}
  local seen = {}
  local function add_slot(slotName)
    if seen[slotName] then return end
    seen[slotName] = true
    local slotCtrl = itemsTab.slots[slotName]
    if not slotCtrl then return end
    local selId = slotCtrl.selItemId or 0
    local entry = { slot = slotName, id = selId }
    if selId > 0 then
      local it = itemsTab.items[selId]
      if it then
        entry.name = it.name
        entry.baseName = it.baseName
        entry.type = it.type
        entry.rarity = it.rarity
        entry.raw = it.raw
      end
    end
    -- Flask/Tincture activation flag stored in activeItemSet
    local set = itemsTab.activeItemSet
    if set and set[slotName] and set[slotName].active ~= nil then
      entry.active = set[slotName].active and true or false
    end
    table.insert(result, entry)
  end
  for _, slot in ipairs(ordered) do
    if slot and slot.slotName then add_slot(slot.slotName) end
  end
  -- Add any remaining slots not in ordered list
  local remainingSlots = {}
  for slotName in pairs(itemsTab.slots or {}) do
    if not seen[slotName] then remainingSlots[#remainingSlots + 1] = slotName end
  end
  table.sort(remainingSlots)
  for _, slotName in ipairs(remainingSlots) do add_slot(slotName) end
  return result
end


-- Skill/Gem Creation and Modification API

-- Create a new socket group
-- params: { label?: string, slot?: string, enabled?: boolean, includeInFullDPS?: boolean }
function M.create_socket_group(params)
  if not build or not build.skillsTab then return nil, 'skills not initialized' end
  if type(params) ~= 'table' then params = {} end

  local socketGroup = {
    label = params.label or '',
    slot = params.slot,
    enabled = params.enabled ~= false,
    includeInFullDPS = params.includeInFullDPS == true,
    gemList = {},
    mainActiveSkill = 1,
    mainActiveSkillCalcs = 1,
  }

  -- Get the active skill set
  local skillSetId = build.skillsTab.activeSkillSetId or 1
  local skillSet = build.skillsTab.skillSets[skillSetId]
  if not skillSet then return nil, 'active skill set not found' end

  -- Add to socket group list
  table.insert(skillSet.socketGroupList, socketGroup)
  local index = #skillSet.socketGroupList

  -- Process the socket group
  if build.skillsTab.ProcessSocketGroup then
    build.skillsTab:ProcessSocketGroup(socketGroup)
  end

  build.buildFlag = true
  M.get_main_output()

  return { index = index, label = socketGroup.label }
end

-- Add a gem to a socket group
-- params: { groupIndex: number, gemName: string, level?: number, quality?: number, qualityId?: string, enabled?: boolean }
function M.add_gem(params)
  if not build or not build.skillsTab then return nil, 'skills not initialized' end
  if type(params) ~= 'table' then return nil, 'invalid params' end
  if not params.groupIndex or not params.gemName then return nil, 'missing groupIndex or gemName' end

  local skillSetId = build.skillsTab.activeSkillSetId or 1
  local skillSet = build.skillsTab.skillSets[skillSetId]
  if not skillSet then return nil, 'active skill set not found' end

  local groupIndex = tonumber(params.groupIndex)
  if not groupIndex or groupIndex ~= math.floor(groupIndex) then return nil, 'invalid groupIndex' end
  local socketGroup = skillSet.socketGroupList[groupIndex]
  if not socketGroup then return nil, 'socket group not found at index ' .. tostring(groupIndex) end

  -- Create gem instance
  local level = tonumber(params.level) or 20
  local quality = tonumber(params.quality) or 0
  local count = tonumber(params.count) or 1
  if level < 1 or level > 40 or level ~= math.floor(level) then return nil, 'invalid level (must be 1-40)' end
  if quality < 0 or quality > 30 or quality ~= math.floor(quality) then return nil, 'invalid quality (must be 0-30)' end
  if count < 1 or count ~= math.floor(count) then return nil, 'invalid count (must be a positive integer)' end

  local findErr, gemData = build.skillsTab:FindSkillGem(tostring(params.gemName))
  if not gemData then return nil, findErr or 'gem not found' end

  local gemInstance = {
    nameSpec = tostring(params.gemName),
    level = level,
    quality = quality,
    qualityId = params.qualityId or 'Default',
    enabled = params.enabled ~= false,
    enableGlobal1 = true,
    enableGlobal2 = false,
    count = count,
    gemId = gemData.id,
    skillId = gemData.grantedEffectId,
    gemData = gemData,
  }

  table.insert(socketGroup.gemList, gemInstance)
  local gemIndex = #socketGroup.gemList

  if build.skillsTab.ProcessSocketGroup then
    build.skillsTab:ProcessSocketGroup(socketGroup)
  end

  build.buildFlag = true
  M.get_main_output()

  return { gemIndex = gemIndex, name = gemInstance.nameSpec }
end

-- Set gem level
-- params: { groupIndex: number, gemIndex: number, level: number }
function M.set_gem_level(params)
  if not build or not build.skillsTab then return nil, 'skills not initialized' end
  if type(params) ~= 'table' then return nil, 'invalid params' end
  if not params.groupIndex or not params.gemIndex or not params.level then
    return nil, 'missing groupIndex, gemIndex, or level'
  end

  local skillSetId = build.skillsTab.activeSkillSetId or 1
  local skillSet = build.skillsTab.skillSets[skillSetId]
  if not skillSet then return nil, 'active skill set not found' end

  local groupIndex = tonumber(params.groupIndex)
  local gemIndex = tonumber(params.gemIndex)
  local level = tonumber(params.level)

  local socketGroup = skillSet.socketGroupList[groupIndex]
  if not socketGroup then return nil, 'socket group not found' end

  local gemInstance = socketGroup.gemList[gemIndex]
  if not gemInstance then return nil, 'gem not found' end

  if level < 1 or level > 40 then return nil, 'invalid level (must be 1-40)' end

  gemInstance.level = level

  if build.skillsTab.ProcessSocketGroup then
    build.skillsTab:ProcessSocketGroup(socketGroup)
  end

  build.buildFlag = true
  M.get_main_output()

  return true
end

-- Set gem quality
-- params: { groupIndex: number, gemIndex: number, quality: number, qualityId?: string }
function M.set_gem_quality(params)
  if not build or not build.skillsTab then return nil, 'skills not initialized' end
  if type(params) ~= 'table' then return nil, 'invalid params' end
  if not params.groupIndex or not params.gemIndex or not params.quality then
    return nil, 'missing groupIndex, gemIndex, or quality'
  end

  local skillSetId = build.skillsTab.activeSkillSetId or 1
  local skillSet = build.skillsTab.skillSets[skillSetId]
  if not skillSet then return nil, 'active skill set not found' end

  local groupIndex = tonumber(params.groupIndex)
  local gemIndex = tonumber(params.gemIndex)
  local quality = tonumber(params.quality)

  local socketGroup = skillSet.socketGroupList[groupIndex]
  if not socketGroup then return nil, 'socket group not found' end

  local gemInstance = socketGroup.gemList[gemIndex]
  if not gemInstance then return nil, 'gem not found' end

  if quality < 0 or quality > 30 then return nil, 'invalid quality (must be 0-30)' end

  gemInstance.quality = quality
  if params.qualityId then
    gemInstance.qualityId = tostring(params.qualityId)
  end

  if build.skillsTab.ProcessSocketGroup then
    build.skillsTab:ProcessSocketGroup(socketGroup)
  end

  build.buildFlag = true
  M.get_main_output()

  return true
end

-- Remove a socket group
-- params: { groupIndex: number }
function M.remove_skill(params)
  if not build or not build.skillsTab then return nil, 'skills not initialized' end
  if type(params) ~= 'table' then return nil, 'invalid params' end
  if not params.groupIndex then return nil, 'missing groupIndex' end

  local skillSetId = build.skillsTab.activeSkillSetId or 1
  local skillSet = build.skillsTab.skillSets[skillSetId]
  if not skillSet then return nil, 'active skill set not found' end

  local groupIndex = tonumber(params.groupIndex)
  local socketGroup = skillSet.socketGroupList[groupIndex]
  if not socketGroup then return nil, 'socket group not found' end

  -- Don't allow removing special groups with sources
  if socketGroup.source then
    return nil, 'cannot remove special socket groups (item/node granted skills)'
  end

  table.remove(skillSet.socketGroupList, groupIndex)

  if build.mainSocketGroup and build.mainSocketGroup > groupIndex then
    build.mainSocketGroup = build.mainSocketGroup - 1
  end
  if build.calcsTab.input.skill_number and build.calcsTab.input.skill_number > groupIndex then
    build.calcsTab.input.skill_number = build.calcsTab.input.skill_number - 1
  end
  if build.skillsTab.RebuildImbuedSupportBySlot then
    build.skillsTab:RebuildImbuedSupportBySlot()
  end

  build.buildFlag = true
  M.get_main_output()

  return true
end

-- Remove a gem from a socket group
-- params: { groupIndex: number, gemIndex: number }
function M.remove_gem(params)
  if not build or not build.skillsTab then return nil, 'skills not initialized' end
  if type(params) ~= 'table' then return nil, 'invalid params' end
  if not params.groupIndex or not params.gemIndex then
    return nil, 'missing groupIndex or gemIndex'
  end

  local skillSetId = build.skillsTab.activeSkillSetId or 1
  local skillSet = build.skillsTab.skillSets[skillSetId]
  if not skillSet then return nil, 'active skill set not found' end

  local groupIndex = tonumber(params.groupIndex)
  local gemIndex = tonumber(params.gemIndex)

  local socketGroup = skillSet.socketGroupList[groupIndex]
  if not socketGroup then return nil, 'socket group not found' end

  local gemInstance = socketGroup.gemList[gemIndex]
  if not gemInstance then return nil, 'gem not found' end

  table.remove(socketGroup.gemList, gemIndex)

  if build.skillsTab.ProcessSocketGroup then
    build.skillsTab:ProcessSocketGroup(socketGroup)
  end

  build.buildFlag = true
  M.get_main_output()

  return true
end


-- Search for passive tree nodes by keyword
-- params: { keyword: string, nodeType?: string ('normal'|'notable'|'keystone'), maxResults?: number, includeAllocated?: boolean }
function M.search_nodes(params)
  if not build or not build.spec then return nil, 'build/spec not initialized' end
  if type(params) ~= 'table' or type(params.keyword) ~= 'string' then
    return nil, 'missing or invalid keyword'
  end

  local keyword = params.keyword:lower()
  local nodeType = params.nodeType and params.nodeType:lower() or nil
  local maxResults = math.min(math.max(math.floor(tonumber(params.maxResults) or 50), 1), 500)
  local includeAllocated = params.includeAllocated ~= false

  local results = {}

  -- Get allocated nodes set for quick lookup
  local allocatedSet = {}
  if build.spec.allocNodes then
    for id, _ in pairs(build.spec.allocNodes) do
      allocatedSet[id] = true
    end
  end

  -- Search through all nodes
  for id, node in pairs(build.spec.nodes) do

    -- Skip if already allocated and we don't want allocated nodes
    if not includeAllocated and allocatedSet[id] then
      goto continue
    end

    -- Filter by node type if specified
    if nodeType then
      local nType = 'normal'
      if node.isKeystone then nType = 'keystone'
      elseif node.isNotable then nType = 'notable'
      elseif node.isJewelSocket then nType = 'jewel'
      elseif node.isMultipleChoiceOption then nType = 'mastery'
      elseif node.ascendancyName then nType = 'ascendancy'
      end
      if nType ~= nodeType then goto continue end
    end

    -- Check if keyword matches name
    local matches = false
    if node.name and node.name:lower():find(keyword, 1, true) then
      matches = true
    end

    -- Check if keyword matches stats/modifiers
    if not matches and node.sd then
      for _, stat in ipairs(node.sd) do
        if type(stat) == 'string' and stat:lower():find(keyword, 1, true) then
          matches = true
          break
        end
      end
    end

    -- Check modifiers list
    if not matches and node.modList then
      for _, mod in ipairs(node.modList) do
        local modStr = tostring(mod)
        if modStr:lower():find(keyword, 1, true) then
          matches = true
          break
        end
      end
    end

    if matches then
      local nodeType = 'normal'
      if node.isKeystone then nodeType = 'keystone'
      elseif node.isNotable then nodeType = 'notable'
      elseif node.isJewelSocket then nodeType = 'jewel'
      elseif node.isMultipleChoiceOption then nodeType = 'mastery'
      elseif node.ascendancyName then nodeType = 'ascendancy'
      end

      local stats = {}
      if node.sd then
        for _, stat in ipairs(node.sd) do
          if type(stat) == 'string' then
            table.insert(stats, stat)
          end
        end
      end

      table.insert(results, {
        id = id,
        name = node.name or 'Unnamed',
        type = nodeType,
        stats = stats,
        allocated = allocatedSet[id] == true,
        x = node.x,
        y = node.y,
        orbit = node.orbit,
        orbitIndex = node.orbitIndex,
        ascendancyName = node.ascendancyName,
      })
    end

    ::continue::
  end

  -- Sort results: keystones first, then notables, then normal
  table.sort(results, function(a, b)
    local typeOrder = { keystone = 1, notable = 2, jewel = 3, mastery = 4, ascendancy = 5, normal = 6 }
    local aOrder = typeOrder[a.type] or 99
    local bOrder = typeOrder[b.type] or 99
    if aOrder ~= bOrder then
      return aOrder < bOrder
    end
    if (a.name or '') ~= (b.name or '') then
      return (a.name or '') < (b.name or '')
    end
    return (tonumber(a.id) or 0) < (tonumber(b.id) or 0)
  end)

  while #results > maxResults do table.remove(results) end

  return { nodes = results, count = #results }
end

local function get_active_skill_set()
  if not build or not build.skillsTab then return nil, 'skills not initialized' end
  local skillSetId = build.skillsTab.activeSkillSetId or 1
  local skillSet = build.skillsTab.skillSets and build.skillsTab.skillSets[skillSetId]
  if not skillSet then return nil, 'active skill set not found' end
  return skillSet
end

-- Toggle an entire socket group without changing its gems.
function M.set_socket_group_enabled(params)
  if type(params) ~= 'table' then return nil, 'invalid params' end
  local groupIndex = tonumber(params.groupIndex)
  if not groupIndex or type(params.enabled) ~= 'boolean' then
    return nil, 'missing groupIndex or enabled'
  end
  local skillSet, err = get_active_skill_set()
  if not skillSet then return nil, err end
  local socketGroup = skillSet.socketGroupList[groupIndex]
  if not socketGroup then return nil, 'socket group not found' end

  socketGroup.enabled = params.enabled
  if build.skillsTab.ProcessSocketGroup then
    build.skillsTab:ProcessSocketGroup(socketGroup)
  end
  build.buildFlag = true
  M.get_main_output()
  return {
    groupIndex = groupIndex,
    label = socketGroup.label or '',
    enabled = socketGroup.enabled,
  }
end

-- Toggle one gem without removing it from its socket group.
function M.set_gem_enabled(params)
  if type(params) ~= 'table' then return nil, 'invalid params' end
  local groupIndex = tonumber(params.groupIndex)
  local gemIndex = tonumber(params.gemIndex)
  if not groupIndex or not gemIndex or type(params.enabled) ~= 'boolean' then
    return nil, 'missing groupIndex, gemIndex, or enabled'
  end
  local skillSet, err = get_active_skill_set()
  if not skillSet then return nil, err end
  local socketGroup = skillSet.socketGroupList[groupIndex]
  if not socketGroup then return nil, 'socket group not found' end
  local gem = socketGroup.gemList[gemIndex]
  if not gem then return nil, 'gem not found' end

  gem.enabled = params.enabled
  if build.skillsTab.ProcessSocketGroup then
    build.skillsTab:ProcessSocketGroup(socketGroup)
  end
  build.buildFlag = true
  M.get_main_output()
  return true
end

-- Return available effects for mastery nodes allocated in the active spec.
function M.get_mastery_options()
  if not build or not build.spec then return nil, 'build/spec not initialized' end
  local spec = build.spec
  local masteries = {}
  for nodeId, node in pairs(spec.allocNodes or {}) do
    if node.type == 'Mastery' and type(node.masteryEffects) == 'table' then
      local availableEffects = {}
      for _, masteryEffect in ipairs(node.masteryEffects) do
        local effectId = tonumber(masteryEffect.effect)
        local effect = effectId and spec.tree.masteryEffects[effectId] or nil
        local stats = effect and effect.sd or masteryEffect.stats or {}
        table.insert(availableEffects, {
          effectId = effectId,
          stat = type(stats) == 'table' and table.concat(stats, '\n') or tostring(stats or ''),
        })
      end
      table.sort(availableEffects, function(a, b) return (a.effectId or 0) < (b.effectId or 0) end)
      table.insert(masteries, {
        nodeId = tonumber(nodeId),
        nodeName = node.name or 'Mastery',
        allocatedEffect = spec.masterySelections and spec.masterySelections[nodeId] or nil,
        availableEffects = availableEffects,
      })
    end
  end
  table.sort(masteries, function(a, b) return a.nodeId < b.nodeId end)
  return { masteries = masteries }
end

local function spec_summary(spec, index, activeIndex)
  local nodeCount = 0
  for _ in pairs(spec.allocNodes or {}) do nodeCount = nodeCount + 1 end
  return {
    index = index,
    title = spec.title or 'Default',
    active = index == activeIndex,
    className = spec.curClassName,
    ascendClassName = spec.curAscendClassName,
    secondaryAscendClassName = spec.curSecondaryAscendClassName,
    classId = spec.curClassId,
    ascendClassId = spec.curAscendClassId,
    secondaryAscendClassId = spec.curSecondaryAscendClassId or 0,
    treeVersion = spec.treeVersion,
    nodeCount = nodeCount,
  }
end

function M.list_specs()
  if not build or not build.treeTab then return nil, 'tree tab not initialized' end
  local result = { activeSpec = build.treeTab.activeSpec, specs = {} }
  for index, spec in ipairs(build.treeTab.specList or {}) do
    table.insert(result.specs, spec_summary(spec, index, build.treeTab.activeSpec))
  end
  return result
end

function M.create_spec(params)
  if not build or not build.treeTab then return nil, 'tree tab not initialized' end
  params = params or {}
  local sourceIndex = tonumber(params.copyFrom) or build.treeTab.activeSpec or 1
  local source = build.treeTab.specList[sourceIndex]
  if not source then return nil, 'copyFrom spec not found' end

  local newSpec = new('PassiveSpec', build, source.treeVersion)
  local state = source:CreateUndoState()
  state.secondaryAscendClassId = source.curSecondaryAscendClassId or 0
  newSpec.jewels = copyTable(source.jewels or {}, true)
  newSpec:RestoreUndoState(state, source.treeVersion)
  newSpec:BuildClusterJewelGraphs()
  newSpec.title = params.title and tostring(params.title) or ((source.title or 'Default') .. ' Copy')
  table.insert(build.treeTab.specList, newSpec)
  if params.activate ~= false then
    build.treeTab:SetActiveSpec(#build.treeTab.specList)
  end
  build.treeTab.modFlag = true
  build.buildFlag = true
  M.get_main_output()
  return M.list_specs()
end

function M.select_spec(params)
  if not build or not build.treeTab then return nil, 'tree tab not initialized' end
  local index = params and tonumber(params.index)
  if not index or not build.treeTab.specList[index] then return nil, 'spec not found' end
  build.treeTab:SetActiveSpec(index)
  build.buildFlag = true
  M.get_main_output()
  return M.list_specs()
end

function M.delete_spec(params)
  if not build or not build.treeTab then return nil, 'tree tab not initialized' end
  local index = params and tonumber(params.index)
  local specs = build.treeTab.specList
  if not index or not specs[index] then return nil, 'spec not found' end
  if #specs <= 1 then return nil, 'cannot delete the only spec' end

  table.remove(specs, index)
  local nextIndex = build.treeTab.activeSpec or 1
  if index < nextIndex then nextIndex = nextIndex - 1 end
  if nextIndex > #specs then nextIndex = #specs end
  build.treeTab:SetActiveSpec(nextIndex)
  build.treeTab.modFlag = true
  build.buildFlag = true
  M.get_main_output()
  return M.list_specs()
end

function M.rename_spec(params)
  if not build or not build.treeTab then return nil, 'tree tab not initialized' end
  local index = params and tonumber(params.index)
  local title = params and params.title
  if not index or not build.treeTab.specList[index] then return nil, 'spec not found' end
  if type(title) ~= 'string' or title:match('^%s*$') then return nil, 'title is required' end
  if #title > 120 then return nil, 'title is too long' end
  build.treeTab.specList[index].title = title
  build.treeTab.modFlag = true
  build.buildFlag = true
  return M.list_specs()
end

function M.list_item_sets()
  if not build or not build.itemsTab then return nil, 'items tab not initialized' end
  local result = { activeItemSetId = build.itemsTab.activeItemSetId, itemSets = {} }
  for _, itemSetId in ipairs(build.itemsTab.itemSetOrderList or {}) do
    local itemSet = build.itemsTab.itemSets[itemSetId]
    if itemSet then
      table.insert(result.itemSets, {
        id = itemSetId,
        title = itemSet.title or 'Default',
        active = itemSetId == build.itemsTab.activeItemSetId,
        useSecondWeaponSet = itemSet.useSecondWeaponSet == true,
      })
    end
  end
  return result
end

function M.select_item_set(params)
  if not build or not build.itemsTab then return nil, 'items tab not initialized' end
  local id = params and tonumber(params.id)
  if not id or not build.itemsTab.itemSets[id] then return nil, 'item set not found' end
  build.itemsTab:SetActiveItemSet(id)
  build.buildFlag = true
  M.get_main_output()
  return M.list_item_sets()
end

function M.save_build(params)
  if type(params) ~= 'table' or type(params.path) ~= 'string' or params.path == '' then
    return nil, 'path is required'
  end
  local xml, err = M.export_build_xml()
  if not xml then return nil, err end
  local file, openErr = io.open(params.path, 'wb')
  if not file then return nil, 'failed to open path: ' .. tostring(openErr) end
  local ok, writeErr = file:write(xml)
  file:close()
  if not ok then return nil, 'failed to write build: ' .. tostring(writeErr) end
  return { path = params.path, size = #xml }
end

return M
