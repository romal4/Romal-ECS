--!optimize 2
--!strict
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

export type Entity<T> = {
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

	_ENTITY_TAG_NAME: string,
	_ENTITY_ID_STRING: string,

	QueryWithout: (withoutList: {string}, ...string) -> () -> (number, ...any),
	QueryWith: (withList: {string}, ...string) -> () -> (number, ...any),
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

--[=[
	@interface Connection
	@within ECS
	@field Disconnect () -> ()
]=]

--[=[
	@interface Event<T>
	@within ECS
	@field Connect (T) -> Connection
	@field Once (T) -> Connection
]=]

--[=[
	@interface Component<T>
	@within ECS
	@field Value T
	@field ComponentChanged Event<T>

	ComponentChanged is read only, Value can be written to.

	```lua
	ECS.CreateComponent("Test", 100)
	ECS.NewEntity()

	local component = ECS.GiveComponent(1, "Test")

	component.ComponentChanged:Connect(function(newValue)
		print(newValue) -- Prints 300
	end)

	component.Value = 300
	```

	You are able to get intellisense by casting the type.

	```lua
	ECS.CreateComponent("Intellisense", true)
	ECS.NewEntity()

	local component = ECS.GiveComponent(1, "Intellisense") :: ECS.Component<boolean>

	component.Value = false -- Valid
	component.Value = 100 -- Type error
	```
]=]

--[=[
	@interface Entity<T>
	@within ECS
	@field Components number
	@field Instance T?
	@field ComponentAdded Event<string>
	@field ComponentRemoved Event<string>

	An entity table, ComponentAdded and ComponentRemoved return the name of the component
	that was removed when calling functions connected to them. All of these values are read only.
]=]

--[=[
	@prop _ENTITY_TAG_NAME string
	@within ECS
	@readonly

	Name of the tag given to instances bound to an entity.
]=]

--[=[
	@prop _ENTITY_ID_STRING string
	@within ECS
	@readonly

	Name of the attribute given to instances bound to an entity. The attribute holds the ID of the entity.
]=]

--[=[
	@class ECS

	Romal's ECS module. Adds support for the ECS paradigm. Provides most common ECS features such as being able to query
	entities.
]=]
local ECS = {
	_ENTITY_TAG_NAME = "Entity",
	_ENTITY_ID_STRING = "EntityID",
} :: ECS

--[=[
	**Used in _for_ loops.** Returns the ID and Value they have with the given components in the second argument, if they contain a component
	that is in the given array, then they are skipped over and not returned.

	@param withoutList {string} -- Components it **must not** have
	@param ... string -- Names of components
	@return number -- ID of Entity
	@return ... any -- Value it has with the given components
]=]
function ECS.QueryWithout(withoutList: {string}, ...: string) : () -> (number, ...any)
	
	local excludeMask = 0b0
	local includeMask = 0b0
	local componentNameList = {...}

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

--[=[
	**Used in _for_ loops.** Returns the ID and Value the entity has with the given components in the second argument.
	Entities must have the component given in the first argument.

	@param withList {string} -- Components it **must** have
	@param ... string --Names of components
	@return number -- ID of Entity
	@return ... any -- Value it has with the given components
]=]
function ECS.QueryWith(withList: {string}, ...: string) : () -> (number, ...any)
	
	local mask = 0b0
	local componentNameList = {...}

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

--[=[
	**Used in _for_ loops.** Returns the ID and the value it currently has with the given components.

	```lua
	ECS.CreateComponent("Test1", 100)
	ECS.CreateComponent("Test2", true)
	ECS.NewEntity()
	ECS.NewEntity()

	local id = ECS.NewEntity()

	ECS.GiveComponent(id, "Test1")

	for i, v in ECS.Query("Test1")
		print(i, v) -- 3 100
		-- Only the third entity is looped over
	end
	```

	@param ... string -- Names of components
	@return number -- ID of Entity
	@return ...any -- Value it has with the given components
]=]
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

--[=[

	Creates a new entity and returns the ID and Entity type, optional instance to bind it to.

	@param instance Instance?
	@return number -- The ID of the Entity
	@return Entity<Instance> -- The Entity table
]=]
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
		instance:AddTag(ECS._ENTITY_TAG_NAME)
		instance:SetAttribute(ECS._ENTITY_ID_STRING, ID)
	end
	
	return ID, entity :: any
end

--[=[
	Creates multiple entities at once, if instanceArray is nil, n is used, if both are
	nil, only one entity is created and returned, ... is the names of the components
	that are given when creating the entities.

	@param n number? -- Defaults to 1
	@param instanceArray {Instance}? -- Priority over n
	@param ... string? -- Components to be given upon creation
	@return {number} -- List of IDs of the entities created
]=]
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

			v:SetAttribute(ECS._ENTITY_ID_STRING, ID)
			v:AddTag(ECS._ENTITY_TAG_NAME)
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

--[=[
	Binds an entity to an instance, if no instance is provided then
	the current instance binded to the entity is unbinded from it.

	@param id number -- Entity ID
	@param instance Instance? -- Instance to bind to, nil if unbinding
]=]
function ECS.BindToInstance(id: number, instance: Instance?) : ()

	local entity = entityList[id]
	local oldInstance = entity.Instance :: Instance?

	if oldInstance then
		oldInstance:SetAttribute(ECS._ENTITY_ID_STRING, nil)
		oldInstance:RemoveTag(ECS._ENTITY_TAG_NAME)
	end

	if instance then
		instance:SetAttribute(ECS._ENTITY_ID_STRING, id)
		instance:AddTag(ECS._ENTITY_TAG_NAME)
	end

	entity.Instance = instance

end

--[=[
	Returns the Entity type

	@param id number -- ID of Entity
	@return Entity<Instance>
]=]
function ECS.GetEntity(id: number) : ReadOnly<Entity<Instance>, "Components">
	return entityList[id] :: any
end

--[=[
	Removes an entity

	@param id number -- ID of Entity
]=]
function ECS.RemoveEntity(id: number) : ()

	local instance = entityList[id].Instance

	if instance then
		instance:RemoveTag(ECS._ENTITY_TAG_NAME)
		instance:SetAttribute(ECS._ENTITY_ID_STRING, nil)
	end

	entityList[id] = nil
	
	for i, v in components do
		v.EntityValues[id] = nil
	end
	
	table.insert(freeIDs, id)

end

--[=[
	Removes all the existing entities
]=]
function ECS.ClearAllEntities() : ()

	for i, v in components do
		table.clear(v.EntityValues)
	end

	table.clear(freeIDs)
	table.clear(entityList)
	entityCount = 0
	
end

--[=[
	Creates a new component with value T, the value given to it will be the default that is
	assigned to entities whenever they are given the component

	@param name string -- Name of component
	@param value T -- Default value for the component
	@error "Invalid value" -- Some values are not valid to be used when making a component
	@error "Exceeded maximum" -- There is a maximum of 32 components that can be created

	:::caution Invalid Values
	**table**, **thread**, **userdata**, and **function** will cause the function to error, these types are not allowed
	to be used for the value of the component
	:::
]=]
function ECS.CreateComponent<T>(name: string, value: T) : ()

	if componentCount >= 32 then
		error("Exceeded maximum of 32 components")
	else
		componentCount += 1
	end

	local valueType = typeof(value)

	if valueType == "table" or valueType == "thread" or valueType == "function" or valueType == "userdata" then
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

--[=[
	Destroys the component, entities with this component will have it removed, frees up space for
	the creation of another component.

	@param name string -- Name of component
]=]
function ECS.DestroyComponent(name: string) : ()

	local bitPos = components[name]._bitPosition

	for i, v in entityList do
		entityList[i].Components = bit32.replace(v.Components, 0, bitPos, 1)
	end

	componentCount -= 1
	table.insert(freeBits, bitPos)
	components[name] = nil

end

--[=[
	Removes a component from a given entity.

	@param id number -- Remove component from an entity
	@param name string -- Name of component to remove
]=]
function ECS.RemoveComponent(id: number, name: string) : ()
	
	local entity = entityList[id]
	local comp = components[name]

	entity.Components = bit32.replace(entity.Components, 0, comp._bitPosition, 1)
	comp.EntityValues[id] = nil
	entity.ComponentRemoved:Fire(name)

end

--[=[
	Gives the component to the given entity, returns the component

	@param id number -- ID of Entity
	@param name string -- Name of component to give
	@return Component<T>
]=]
function ECS.GiveComponent<T>(id: number, name: string) : Component<T>

	local comp = components[name]
	local entity = entityList[id]
	local template = comp._template
	local internal = {Value = template}
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

--[=[
	Checks if the given entity has the specified component.

	@param id number -- ID of entity
	@param name string -- Name of component
	@return boolean
]=]
function ECS.HasComponent(id: number, name: string) : boolean
	return bit32.extract(entityList[id].Components, components[name]._bitPosition, 1) == 1
end

return ECS