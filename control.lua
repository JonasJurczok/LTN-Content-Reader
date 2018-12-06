
-- OnTick and OnDispatcherUpdated are NOT synchronized
-- setting UpdateInterval to <= 60 ensures all combinators are updated between each trigger of OnDispatcherUpdated
local UpdateInterval = settings.global["ltn_content_reader_update_interval"].value

script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
  if event.setting == "ltn_content_reader_update_interval" then
    UpdateInterval = settings.global["ltn_content_reader_update_interval"].value
  end
end)

-- LTN interface event functions
function OnStopsUpdated(event)
  if event.data then
    --log("Stop Data:"..serpent.block(event.data) )
    global.stop_network_ID = {}

    -- build stop netwok_ID lookup table
    for stopID, stop in pairs(event.data) do
      if stop then
        global.stop_network_ID[stopID] = stop.network_id
      end
    end
  end
end

function OnDispatcherUpdated(event)
  -- ltn provides data per stop, aggregate over network and item
  global.ltn_provided = {}
  if event.data and event.data.Provided then
    -- data.Provided = { [item], { [stopID], count } }
    for item, stops in pairs(event.data.Provided) do
      for stopID, count in pairs(stops) do
        local networkID = global.stop_network_ID[stopID]
        if networkID then
          global.ltn_provided[networkID] = global.ltn_provided[networkID] or {}
          global.ltn_provided[networkID][item] = (global.ltn_provided[networkID][item] or 0) + count
        end
      end
    end
  end

  if event.data and event.data.Requests then
    global.ltn_requested = {}
    -- data.Requests = { stopID, item, count }
    for _, request in pairs(event.data.Requests) do
      local networkID = global.stop_network_ID[request.stopID]
      if networkID then
        global.ltn_requested[networkID] = global.ltn_requested[networkID] or {}
        global.ltn_requested[networkID][request.item] = (global.ltn_requested[networkID][request.item] or 0) - request.count
      end
    end
  end
end

-- spread out updating combinators
function OnTick(event)
  local offset = event.tick % UpdateInterval
  local cc_count = #global.content_combinators
  for i=cc_count - offset, 1, -1 * UpdateInterval do
    -- log( "("..tostring(event.tick)..") on_tick updating "..i.."/"..cc_count )
    local combinator = global.content_combinators[i]
    if combinator.valid then
      Update_Combinator(combinator)
    else
      table.remove(global.content_combinators, i)
      if #global.content_combinators == 0 then
        script.on_event(defines.events.on_tick, nil)
      end
    end
  end
end


function Update_Combinator(combinator)
  -- get network id from combinator parameters
  local first_signal = combinator.get_control_behavior().get_signal(1)
  local selected_networkID = -1

  if first_signal and first_signal.signal and first_signal.signal.name == "ltn-network-id" then
    selected_networkID = first_signal.count
  else
    log("Error: combinator must have ltn-network-id set at index 1. Setting network id to -1 (any).")
  end

  local index = 1
  local signals = { { index = 1, signal = {type="virtual", name="ltn-network-id"}, count = selected_networkID } }


  -- for many signals performance is better to aggregate first instead of letting factorio do it
  local items = {}
  local bit_and = bit32.band
  local string_match = string.match

  if combinator.name == "ltn-provider-reader" then
    for networkID, item_data in pairs(global.ltn_provided) do
      if bit_and(selected_networkID, networkID) ~= 0 then
        for item, count in pairs(item_data) do
          items[item] = (items[item] or 0) + count
        end
      end
    end
  end

  if combinator.name == "ltn-requester-reader" then
    for networkID, item_data in pairs(global.ltn_requested) do
      if bit_and(selected_networkID, networkID) ~= 0 then
        for item, count in pairs(item_data) do
          items[item] = (items[item] or 0) + count
        end
      end
    end
  end

  -- log("DEBUG: Items in network "..selected_networkID..": "..serpent.block(items) )

  -- generate signals from aggregated item list
  for item, count in pairs(items) do
    local itype, iname = string_match(item, "([^,]+),([^,]+)")
    if itype and iname and (game.item_prototypes[iname] or game.fluid_prototypes[iname]) then
      index = index+1
      signals[#signals+1] = {index = index, signal = {type=itype, name=iname}, count = count}
      -- table.insert(signals, {index = index, signal = {type=itype, name=iname}, count = count})
    end
  end
  combinator.get_control_behavior().parameters = { parameters = signals }
end


-- add/remove event handlers
function OnEntityCreated(event)
  local entity = event.created_entity
  if entity.name == "ltn-provider-reader" or entity.name == "ltn-requester-reader" then
    -- if not set use default network id -1 (any network)
    local first_signal = entity.get_control_behavior().get_signal(1)
    if not (first_signal and first_signal.signal and first_signal.signal.name == "ltn-network-id") then
      entity.get_or_create_control_behavior().parameters = { parameters = { { index = 1, signal = {type="virtual", name="ltn-network-id"}, count = -1 } } }
    end

    table.insert(global.content_combinators, entity)

    if #global.content_combinators == 1 then
      script.on_event(defines.events.on_tick, OnTick)
    end
  end
end

function OnEntityRemoved(event)
  local entity = event.entity
  if entity.name == "ltn-provider-reader" or entity.name == "ltn-requester-reader" then
    for i=#global.content_combinators, 1, -1 do
      if global.content_combinators[i].unit_number == entity.unit_number then
        table.remove(global.content_combinators, i)
      end
    end

    if #global.content_combinators == 0 then
			script.on_event(defines.events.on_tick, nil)
    end
  end
end

---- Initialisation  ----
do
local function init_globals()
  global.stop_network_ID = global.stop_network_ID or {}
  global.ltn_contents = nil
  global.ltn_provided = global.ltn_provided or {}
  global.ltn_requested = global.ltn_requested or {}
  global.content_combinators = global.content_combinators or {}
end

local function register_events()
  -- register events from LTN
  if remote.interfaces["logistic-train-network"] then
    script.on_event(remote.call("logistic-train-network", "get_on_stops_updated_event"), OnStopsUpdated)
    script.on_event(remote.call("logistic-train-network", "get_on_dispatcher_updated_event"), OnDispatcherUpdated)
  end

  -- register game events
  script.on_event({defines.events.on_built_entity, defines.events.on_robot_built_entity}, OnEntityCreated)
  script.on_event({defines.events.on_pre_player_mined_item, defines.events.on_robot_pre_mined, defines.events.on_entity_died}, OnEntityRemoved)
  if #global.content_combinators > 0 then
    script.on_event(defines.events.on_tick, OnTick)
  end
end


script.on_init(function()
  init_globals()
  register_events()
end)

script.on_configuration_changed(function(data)
  init_globals()
  register_events()
end)

script.on_load(function(data)
  register_events()
end)
end