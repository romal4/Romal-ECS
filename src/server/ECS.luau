--!optimize 2
--!strict
local ENTITY_TAG_NAME = "Entity"
local ENTITY_ID_STRING = "EntityID"
-- Constants

local freeIDs = table.create(100)
local freeBits = table.create(32)
local entityList: {InternalEntity<Instance>} = {}
local components = {} :: {[string]: ComponentTable<any>}
local componentCount = 0
local nextBitPos = 0
local entityCount = 0

type function ReadOnly(t, keys)

	local result = types.copy(t)

	if keys:is("union") then
		for _, k in keys:components() do
			local readType = result:readproperty(k)
			if readType then
				result:setwriteproperty(k, nil)
			end
		end
	else

		local readType = result:readproperty(keys)
		if readType then
			result:setwriteproperty(keys, nil)
		end
	end
	
	return result
end

type Connection = {
	Disconnect: (self: Connection) -> (),
}

type Event<T> = {
	Connect: (self: Event<T>, f: (T) -> ()) -> Connection,
	Once: (self: Event<T>, f: (T) -> ()) -> Connection,
}

export type Component<T> = {
	Value: T,
	ComponentChanged: Event<T>,
}

type InternalEntity<T> = {
	Instance: T?,
	Components: number,
	ComponentAdded: Signal,
	ComponentRemoved: Signal,
}

type Entity<T> = {
	Instance: T?,
	Components: number,
	ComponentAdded: Event<string>,
	ComponentRemoved: Event<string>,
}

type ComponentTable<T> = {
	_bitPosition: number,
	_template: T,
	EntityValues: {Component<any>}
}

type Signal = {
	_listeners: {[(...any) -> ()]: boolean} ,
	Fire: (self: Signal, ...any) -> (),
	Connect: (self: Signal, f: (...any) -> ()) -> Connection,
	Once: (self: Signal, f: (...any) -> ()) -> Connection,
}

type ECS = {

	QueryWithout: (withoutList: {string}, componentNameList: {string}) -> () -> (number, ...any),
	QueryWith: (withList: {string}, componentNameList: {string}) -> () -> (number, ...any),
	Query: (...string) -> () -> (number, ...any),
	
	NewEntity: (instance: Instance?) -> (number, ReadOnly<Entity<Instance>, "Components" | "ComponentAdded" | "ComponentRemoved" | "Instance">),
	BulkNewEntities: (n: number?, instanceList: {Instance}?, ...string?) -> {number},
	BindToInstance: (id: number, instance: Instance) -> (),
	GetEntity: (id: number) -> ReadOnly<Entity<Instance>, "Components" | "ComponentAdded" | "ComponentRemoved" | "Instance">,
	RemoveEntity: (id: number) -> (),
	ClearAllEntities: () -> (),
	
	CreateComponent: <T>(name: string, value: T) -> (),
	DestroyComponent: (name: string) -> (),
	RemoveComponent: (id: number, name: string) -> (),
	GiveComponent: <T>(id: number, componentName: string) -> Component<T>,
	HasComponent: (id: number, name: string) -> boolean,

}

local signal = {}
signal.__index = signal

function signal.new() : Signal
	return setmetatable({_listeners = {}}, signal) :: any
end

function signal.Fire(self: Signal, ...: any)
	for f in self._listeners do
		task.spawn(f, ...)
	end
end

function signal.Connect(self: Signal, f: (...any) -> ()) : Connection

	self._listeners[f] = true

	return {
		Disconnect = function()
			self._listeners[f] = nil
		end
	}
end

function signal.Once(self: Signal, f: (...any) -> ()) : Connection

	local conn: Connection

	conn = self:Connect(function(...)
		conn:Disconnect()
		f(...)
	end)

	return conn
end

local function bulkEntityBitMask(id: number, name: string) : ()

	local comp = components[name]
	local entity = entityList[id]
	local internal = {Value = comp._template}
	local newSignal = signal.new()
	local userdata = newproxy(true)
	local mt = getmetatable(userdata)

	mt.__index = function(_, k)
		if k == "ComponentChanged" then return newSignal
		elseif k == "Value" then return internal.Value
		else error("Attempted to index a non existing key") end
	end

	mt.__newindex = function(_, k, v)
		if k == "Value" then
			internal.Value = v
			newSignal:Fire(v)
		else
			error("Attempted to change a non existing key")
		end
	end

	comp.EntityValues[id] = userdata
	entity.ComponentAdded:Fire(name)
	
end

local ECS = {} :: ECS

function ECS.QueryWithout(withoutList: {string}, componentNameList: {string}) : () -> (number, ...any)
	
	local excludeMask = 0b0
	local includeMask = 0b0

	for _, v in withoutList do
		excludeMask = bit32.replace(excludeMask, 1, components[v]._bitPosition, 1)
	end

	for _, v in componentNameList do
		includeMask = bit32.replace(includeMask, 1, components[v]._bitPosition, 1)
	end

	local idsToIterate = {}
	local index = 0

	for i, v in entityList do
		if bit32.band(v.Components, includeMask) == includeMask and bit32.band(v.Components, excludeMask) == 0 then
			table.insert(idsToIterate, i)
		end
	end

	return function()
		
		index += 1
		local id = idsToIterate[index]

		if id == nil then return nil :: any end

		local t = {id}

		for _, v in componentNameList do
			table.insert(t, components[v].EntityValues[id].Value)
		end

		return table.unpack(t)
	end
end

function ECS.QueryWith(withList: {string}, componentNameList: {string}) : () -> (number, ...any)
	
	local mask = 0b0

	for _, v in componentNameList do
		mask = bit32.replace(mask, 1, components[v]._bitPosition, 1)
	end

	for _, v in withList do
		mask = bit32.replace(mask, 1, components[v]._bitPosition, 1)
	end

	local idsToIterate = {}
	local index = 0

	for i, v in entityList do
		if bit32.band(v.Components, mask) == mask then
			table.insert(idsToIterate, i)
		end
	end

	return function()

		index += 1
		local id = idsToIterate[index]

		if id == nil then return nil :: any end

		local t = {id}

		for _, v in componentNameList do
			table.insert(t, components[v].EntityValues[id].Value)
		end
		
		return table.unpack(t)
	end
end

function ECS.Query(...: string) : () -> (number, ...any)

	local componentNameList = {...}
	local mask = 0b0

	for _, v in componentNameList do
		mask = bit32.replace(mask, 1, components[v]._bitPosition, 1)
	end

	local idsToIterate = {}
	local index = 0

	for i, v in entityList do
		if bit32.band(v.Components, mask) == mask then
			table.insert(idsToIterate, i)
		end
	end

	return function()
		
		index += 1
		local id = idsToIterate[index]

		if id == nil then return nil :: any end

		local t = {id}

		for _, v in componentNameList do
			table.insert(t, components[v].EntityValues[id].Value)
		end

		return table.unpack(t)
	end
end

function ECS.NewEntity(instance: Instance?) : (number, ReadOnly<Entity<Instance>, "Components">)
	
	local ID = 0

	if #freeIDs > 0 then
		ID = table.remove(freeIDs) :: number
	else
		entityCount += 1
		ID = entityCount
	end

	entityList[ID] = {
		Instance = instance,
		Components = 0b0,
		ComponentAdded = signal.new(),
		ComponentRemoved = signal.new(),
	}
	
	local entity = entityList[ID] 

	if instance then
		instance:AddTag(ENTITY_TAG_NAME)
		instance:SetAttribute(ENTITY_ID_STRING, ID)
	end
	
	return ID, entity :: any
end

function ECS.BulkNewEntities(n: number?, instanceArray: {Instance}?, ...:string?) : {number}

	local componentNameList = {...} :: any
	local m = n or 1
	local entityReturnList = {}

	if #componentNameList > 32 then 
		error("Component list exceeds 32") 
	end

	local ID = 0

	if instanceArray then
		for i, v in instanceArray do

			if #freeIDs > 0 then
				ID = table.remove(freeIDs) :: number
			else
				entityCount += 1
				ID = entityCount
			end

			v:SetAttribute(ENTITY_ID_STRING, ID)
			v:AddTag(ENTITY_TAG_NAME)
			entityList[ID] = {
				Instance = v,
			 	Components = 0b0,
				ComponentAdded = signal.new(),
				ComponentRemoved = signal.new(),
			}
			table.insert(entityReturnList, ID)

			if #componentNameList > 0 then
				
				local mask = 0b0

				for _, v: string in componentNameList do
					mask = bit32.replace(mask, 1, components[v]._bitPosition, 1)
				end

				entityList[ID].Components = bit32.bor(entityList[ID].Components, mask)

				for _, v: string in componentNameList do
					bulkEntityBitMask(ID, v)
				end
			end
		end
	else
		for i = 1, m do

			if #freeIDs > 0 then
				ID = table.remove(freeIDs) :: number
			else
				entityCount += 1
				ID = entityCount
			end

			entityList[ID] = {
				Components = 0b0,
				ComponentAdded = signal.new(),
				ComponentRemoved = signal.new(),
			}
			table.insert(entityReturnList, ID)

			if #componentNameList > 0 then
				
				local mask = 0b0

				for _, v: string in componentNameList do
					mask = bit32.replace(mask, 1, components[v]._bitPosition, 1)
				end

				entityList[ID].Components = bit32.bor(entityList[ID].Components, mask)

				for _, v: string in componentNameList do
					bulkEntityBitMask(ID, v)
				end
			end
		end
	end
	return entityReturnList
end

function ECS.BindToInstance(id: number, instance: Instance?) : ()

	local entity = entityList[id]
	local oldInstance = entity.Instance :: Instance?

	if oldInstance then
		oldInstance:SetAttribute(ENTITY_ID_STRING, nil)
		oldInstance:RemoveTag(ENTITY_TAG_NAME)
		entity.Instance = nil
	end

	if instance then
		instance:SetAttribute(ENTITY_ID_STRING, id)
		instance:AddTag(ENTITY_TAG_NAME)
	end

	entity.Instance = instance

end

function ECS.GetEntity(id: number) : ReadOnly<Entity<Instance>, "Components">
	return entityList[id] :: any
end

function ECS.RemoveEntity(id: number) : ()

	local instance = entityList[id].Instance

	if instance then
		instance:RemoveTag(ENTITY_TAG_NAME)
		instance:SetAttribute(ENTITY_ID_STRING, nil)
	end

	entityList[id] = nil
	
	for i, v in components do
		v.EntityValues[id] = nil
	end
	
	table.insert(freeIDs, id)

end

function ECS.ClearAllEntities() : ()

	for i, v in components do
		table.clear(v.EntityValues)
	end

	table.clear(freeIDs)
	table.clear(entityList)
	entityCount = 0
	
end

function ECS.CreateComponent<T>(name: string, value: T) : ()

	if componentCount >= 32 then
		error("Exceeded maximum of 32 components")
	else
		componentCount += 1
	end

	local valueType = typeof(value)

	if valueType == "table" or valueType == "thread" or valueType == "function" then
		error(`{valueType} is not a valid component value`)
	end

	valueType = nil :: any

	local freeBitSpace = #freeBits

	components[name] = {
		_bitPosition = if freeBitSpace > 0 then table.remove(freeBits) :: number else nextBitPos,
		EntityValues = {},
		_template = value
	}

	if freeBitSpace == 0 then
		nextBitPos += 1
	end
end

function ECS.DestroyComponent(name: string) : ()

	local bitPos = components[name]._bitPosition

	for i, v in entityList do
		entityList[i].Components = bit32.replace(v.Components, 0, bitPos, 1)
	end

	componentCount -= 1
	table.insert(freeBits, bitPos)
	components[name] = nil

end

function ECS.RemoveComponent(id: number, name: string) : ()
	
	local entity = entityList[id]

	entity.Components = bit32.replace(entity.Components, 0, components[name]._bitPosition, 1)
	components[name].EntityValues[id] = nil
	entity.ComponentRemoved:Fire(name)

end

function ECS.GiveComponent<T>(id: number, name: string) : Component<T>

	local comp = components[name]
	local entity = entityList[id]
	local internal = {Value = comp._template}
	local newSignal = signal.new()
	local userdata = newproxy(true)
	local mt = getmetatable(userdata)

	mt.__index = function(_, k)
		if k == "ComponentChanged" then return newSignal
		elseif k == "Value" then return internal.Value
		else error("Attempted to index a non existing key") end
	end

	mt.__newindex = function(_, k, v)
		if k == "Value" then
			internal.Value = v
			newSignal:Fire(v)
		else
			error("Attempted to change a non existing key")
		end
	end

	entity.Components = bit32.replace(entityList[id].Components, 1, comp._bitPosition, 1)
	comp.EntityValues[id] = userdata :: Component<T>
	entity.ComponentAdded:Fire(name)

	return userdata :: Component<T>
end

function ECS.HasComponent(id: number, name: string) : boolean
	return bit32.extract(entityList[id].Components, components[name]._bitPosition, 1) == 1
end

return ECS