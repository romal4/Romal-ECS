--!optimize 2
--!strict
local freeIndexes: {number} = {}
local freeIDs = table.create(100) :: {number}
local freeBits = table.create(32) :: {number}
local entityList: {InternalEntity<Instance>} = {}
local components = {} :: {[string]: ComponentTable<any>}
local componentValueList: {{any}} = {}
local threads: {() -> ()} = {}
local deferredThreads: {() -> ()} = {}
local listenerCount: {number} = {}
local deferredListenerCount: {number} = {}
local componentCount = 0
local nextBitPos = 0
local entityCount = 0

type InternalConnection = {
	__index: InternalConnection,
	Disconnect: (self: Connection) -> (),
}

type Connection = {
	Disconnect: (self: Connection) -> (),
}

type Event<T> = {
	Connect: (self: Event<T>, f: (T) -> ()) -> Connection,
	Once: (self: Event<T>, f: (T) -> ()) -> Connection,
	Wait: <T>(self: Event<T>) -> T,
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

type SignalMetatable = {
	__index: SignalMetatable,
	Fire: (self: Signal, ...any) -> (),
	Connect: (self: Signal, f: (...any) -> ()) -> Connection,
	ConnectDeferred: (self: Signal, f: (...any) -> ()) -> Connection,
	Once: (self: Signal, f: (...any) -> ()) -> Connection,
	Wait: <T>(self: Signal) -> T,
}

type Signal = setmetatable<{number}, SignalMetatable>

type InternalIterator = {
	List: {number},
	ComponentList: {string},
}

type IteratorMetatable = {
	__index: IteratorMetatable,
	__iter: (t: InternalIterator) -> () -> (number, ...any),
	With: (self: InternalIterator, ...string) -> Iterator,
	Without: (self: InternalIterator, ...string) -> Iterator,
}

type Iterator = {
	With: (self: Iterator, ...string) -> Iterator,
	Without: (self: Iterator, ...string) -> Iterator,
}

type EntitySingleton = "Components" | "Instance"

type ECS = {

	_ENTITY_TAG_NAME: string,
	_ENTITY_ID_STRING: string,

	Query: (...string) -> Iterator,
	
	NewEntity: (instance: Instance?) -> (number, Entity<Instance>),
	BulkNewEntities: (n: number?, instanceList: {Instance}?, ...string?) -> {number},
	BindToInstance: (id: number, instance: Instance) -> (),
	GetEntity: (id: number) -> Entity<Instance>,
	RemoveEntity: (id: number) -> (),
	ClearAllEntities: () -> (),
	GetAllIDs: () -> {number},
	
	CreateComponent: <T>(name: string, value: T) -> (),
	DestroyComponent: (name: string) -> (),
	RemoveComponent: (id: number, name: string) -> (),
	GiveComponent: <T>(id: number, componentName: string, defaultInstance: Instance?) -> Component<T>,
	HasComponent: (id: number, name: string) -> boolean,

}

--[=[
	Iterator class returned by the Query() function

	@class Iterator
]=]

local iterator = {} :: IteratorMetatable
iterator.__index = iterator
iterator.__iter = function(t: InternalIterator) : () -> (number, ...any)

	local index: number

	return function()

		local newIndex, id = next(t.List, index)

		if id == nil then return nil :: any end
		index = newIndex :: number

		local returnTable = table.create(#t.ComponentList + 1) :: {number}
		returnTable[1] = id
	
		for _, v in t.ComponentList do
			table.insert(returnTable, components[v].EntityValues[id].Value)
		end

		return table.unpack(returnTable)
	end
end

--[=[
	Only iterates over entities with the specified components.

	```lua
	ECS.GiveComponent(1, "A")
	ECS.GiveComponent(2, "B")
	ECS.GiveComponent(3, "A")
	-- Assuming they all have a "C" Component with a bool value

	for id, value in ECS.Query("C"):With("A") do
		print(id, value)
		-- 1 true
		-- 3 true
		-- Entity 2 is skipped as it does not have "A" Component
	end
	```

	@method With
	@within Iterator
	@param ... string -- Names of components
	@return Iterator
]=]
function iterator.With(self: InternalIterator, ...: string) : Iterator
	
	local mask = 0b0

	local reference = self.List
	local componentNameList = {...}

	for _, v in componentNameList do
		mask = bit32.replace(mask, 1, components[v]._bitPosition)
	end

	for i, v in reference do
		if bit32.band(mask, entityList[v].Components) ~= mask then
			reference[i] = nil
		end
	end

	return self :: any
end

--[=[
	Only iterates over entities that do not have the specified components.

	```lua
	ECS.GiveComponent(1, "A")
	ECS.GiveComponent(2, "B")
	ECS.GiveComponent(3, "A")
	-- Assume they all have a "C" Component with a bool value

	for id, value in ECS.Query("C"):Without("A") do
		print(id, value)
		-- 2 true
		-- Entities 1 and 3 are skipped as they have the "A" Component
	end
	```

	@method Without
	@within Iterator
	@param ... string -- Names of components
	@return Iterator
]=]
function iterator.Without(self: InternalIterator, ...: string) : Iterator

	local mask = 0b0

	local reference = self.List
	local componentNameList = {...}

	for _, v in componentNameList do
		mask = bit32.replace(mask, 1, components[v]._bitPosition)
	end

	for i, v in reference do
		if bit32.band(mask, entityList[v].Components) ~= 0 then
			reference[i] = nil
		end
	end
	
	return self :: any
end

--[=[
	Type returned by calling the methods of Event.

	@class Connection
]=]
local connection = {} :: InternalConnection
connection.__index = connection

--[=[
	Disconnects a function from an event.

	@method Disconnect
	@within Connection
]=]
function connection.Disconnect(self: Connection) : ()

	local index = (self :: any)[1]
	local originalSignal = (self :: any)[2]
	local pos = table.find(originalSignal, index)

	if pos then table.remove(originalSignal, pos) end
	
    if index > 0 then

        listenerCount[index] -= 1

        if listenerCount[index] == 0 then

            threads[index] = nil
            listenerCount[index] = nil
            table.insert(freeIndexes, index)

        end
    else

        local absIndex = -index
        deferredListenerCount[absIndex] -= 1

        if deferredListenerCount[absIndex] == 0 then

            deferredThreads[absIndex] = nil
            deferredListenerCount[absIndex] = nil
            table.insert(freeIndexes, absIndex)

        end
    end

	(self :: any)[2] = nil
	setmetatable(self, nil)
end

--[=[
	@class Event

	Event type
]=]

local signal = {}
signal.__index = signal

function signal.new() : Signal
	return setmetatable({}, signal) :: any
end

function signal.Fire(self: Signal, ...: any)
	for _, v in self do
        if v > 0 then
            local f = threads[v]
            if f then task.spawn(f, ...) end
        else
            local f = deferredThreads[-v]
            if f then task.defer(f, ...) end
        end
    end
end

--[=[
	Connects the given function to the event.

	@method Connect
	@within Event
	@param f (...any) -> () -- Function to connect to
	@return Connection
]=]
function signal.Connect(self: Signal, f: (...any) -> ()) : Connection

	local index = table.find(threads :: any, f) :: number

	if not index then
		if #freeIndexes > 0 then
			index = math.abs(table.remove(freeIndexes) :: number)
		else
			index = #threads + 1
		end
	end

	if not listenerCount[index] then
		listenerCount[index] = 1
	else
		listenerCount[index] += 1
	end

	table.insert(self, index)
	
	local newConnection = setmetatable({
		[1] = index,
		[2] = self,
	}, connection)

	threads[index] = f

	return newConnection :: Connection
end

--[=[
	Connects the given function to the event, calls it using task.defer().

	@method ConnectDeferred
	@within Event
	@param f (...any) -> () -- Function to connect to
	@return Connection
]=]
function signal.ConnectDeferred(self: Signal, f: (...any) -> ()) : Connection

	local index = table.find(deferredThreads :: any, f) :: number

	if not index then
		if #freeIndexes > 0 then
			index = math.abs(table.remove(freeIndexes) :: number)
		else
			index = #deferredThreads + 1
		end
	end

	if not deferredListenerCount[index] then
		deferredListenerCount[index] = 1
	else
		deferredListenerCount[index] += 1
	end

	table.insert(self, -index)
	
	local newConnection = setmetatable({
		[1] = -index,
		[2] = self,
	}, connection)

	deferredThreads[index] = f

	return newConnection :: Connection
end

--[=[
	Connects to the given function, upon being called for the first time it automatically disconnects the connection.

	@method Once
	@within Event
	@param f (...any) -> () -- Function to connect to
	@return Connection
]=]
function signal.Once(self: Signal, f: (...any) -> ()) : Connection

	local conn: Connection

	conn = self:Connect(function(...)
		conn:Disconnect()
		f(...)
	end)

	return conn
end

--[=[
	Yields the current thread until the event is activated, returns the values from the event its connected to.

	@method Wait
	@within Event
	@return T
]=]
function signal.Wait<T>(self: Signal) : T

	local currentThread = coroutine.running()
	
	self:Once(function(...)
		coroutine.resume(currentThread, ...)
	end)
	
	return coroutine.yield()
end

local function bulkEntityBitMask(id: number, name: string) : ()

	local comp = components[name]
	local entity = entityList[id]
	local pos = comp._bitPosition
	local template = comp._template
	local newSignal = signal.new()
	local userdata = newproxy(true)
	local mt = getmetatable(userdata)

	componentValueList[id] = componentValueList[id] or {}
	componentValueList[id][pos] = template

	mt.__index = function(_, k)
		if k == "ComponentChanged" then return newSignal
		elseif k == "Value" then return componentValueList[id][pos]
		else error("Attempted to index a non existing key", 2) end
	end

	if template ~= nil then
		mt.__newindex = function(_, k: string, v)
			if k == "Value" then
				componentValueList[id][pos] = v
				newSignal:Fire(v)
			else
				error("Attempted to change a non existing key", 2)
			end
		end
	else
		mt.__newindex = function(_, k: string, v)
			if k == "Value" then
				if typeof(v) == "Instance" then
					componentValueList[id][pos] = v
					newSignal:Fire(v)
				else
					error("Assigned value must be of Instance type", 2)
				end
			else
				error("Attempted to change a non existing key", 2)
			end
		end
	end

	comp.EntityValues[id] = userdata
	entity.ComponentAdded:Fire(name)
	
end

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

	You will get an error if you attempt to run the following code.

	```lua
	ECS.CreateComponent("Errors", 0)
	ECS.NewEntity()

	local component = ECS.GiveComponent(1, "Errors")

	component.ComponentChanged = "foo" -- Error
	component.NewKey = "bar" -- Error
	print(component.RealValue) -- Error
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

	Intellisense is supported by casting the type

	```lua
	local part = workspace.Part
	local entity = select(-1, ECS.NewEntity(part)) :: ECS.Entity<BasePart>

	print(entity.Instance.Position)
	```

]=]

--[=[
	@prop _ENTITY_TAG_NAME string
	@within ECS
	@readonly

	Name of the CollectionService tag given to instances bound to an entity.
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
local ECS = { -- Modify these strings if you wish to change the tag or attribute name
	_ENTITY_TAG_NAME = "Entity",
	_ENTITY_ID_STRING = "EntityID",
} :: ECS

--[=[
	Returns the ID and the value it currently has with the given components.

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

	@tag Iterator
	@param ... string -- Names of components
	@return Iterator
	@error Missing arguments -- No arguments were provided to the function
]=]
function ECS.Query(...: string) : Iterator

	local mask = 0b0

	local componentNameList = {...}
	local idsToIterate = {}

	for _, v in componentNameList do
		mask = bit32.replace(mask, 1, components[v]._bitPosition)
	end

	if mask == 0 then
		error("Missing arguments in Query()", 2)
	end

	for i, v in entityList do
		if bit32.band(v.Components, mask) == mask then
			table.insert(idsToIterate, i)
		end
	end

	return setmetatable({
		List = idsToIterate,
		ComponentList = componentNameList,
	}, iterator) :: Iterator
end

--[=[

	Creates a new entity and returns the ID and Entity type, optional instance to bind it to.

	@param instance Instance?
	@return number -- The ID of the Entity
	@return Entity<Instance> -- The Entity table
]=]
function ECS.NewEntity(instance: Instance?) : (number, Entity<Instance>)
	
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
					mask = bit32.replace(mask, 1, components[v]._bitPosition)
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
					mask = bit32.replace(mask, 1, components[v]._bitPosition)
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
	Returns the entity with the given ID.

	@param id number -- ID of Entity
	@return Entity<Instance>
]=]
function ECS.GetEntity(id: number) : Entity<Instance>
	return entityList[id] :: any
end

--[=[
	Removes an entity.

	@param id number -- ID of Entity
]=]
function ECS.RemoveEntity(id: number) : ()

	local instance = entityList[id].Instance

	if instance then
		instance:RemoveTag(ECS._ENTITY_TAG_NAME)
		instance:SetAttribute(ECS._ENTITY_ID_STRING, nil)
	end

	componentValueList[id] = nil
	entityList[id] = nil
	
	for i, v in components do
		v.EntityValues[id] = nil
	end
	
	table.insert(freeIDs, id)

end

--[=[
	Removes all the existing entities.
]=]
function ECS.ClearAllEntities() : ()

	for i, v in components do
		table.clear(v.EntityValues)
	end

	table.clear(freeIDs)
	table.clear(entityList)
	table.clear(componentValueList)
	entityCount = 0
	
end

--[=[
	Returns all the existing IDs of all entities.

	@return {number} -- Array of IDs
]=]
function ECS.GetAllIDs() : {number}
	
	local t = {}

	for i in entityList do
		table.insert(t, i)
	end

	return t
end

--[=[
	Creates a new component with value T, the value given to it will be the default that is
	assigned to entities whenever they are given the component.

	@param name string -- Name of component
	@param value T -- Default value for the component
	@error Invalid value -- Value given is an invalid value
	@error Exceeded maximum -- There is a maximum of 32 components that can be created
	@error Already existing componnet -- A component with the same name already exists

	```lua
	ECS.CreateComponent("Test", 1000) -- 1000 is the default value
	ECS.NewEntity()

	local component = ECS.GiveComponent(1, "Test")
	print(component.Value) -- 1000
	```

	Different behavior is applied when the value is of type Instance. The default value of the component
	will be nil, entities that are given this component will also have a value of nil unless given a
	default instance to use when calling GiveComponent().

	:::caution Invalid Values
	`table`, `thread`, `userdata`, and `function` will cause the function to error, these types are not allowed
	to be used for the value of the component.
	:::
]=]
function ECS.CreateComponent<T>(name: string, value: T) : ()

	assert(not components[name], `A component with the name {name} already exists`)

	local valueType = typeof(value)

	if valueType == "table" or valueType == "thread" or valueType == "function" or valueType == "userdata" then
		error(`{valueType} is not a valid component value`, 2)
	end

	if componentCount >= 32 then
		error("Exceeded maximum of 32 components")
	else
		componentCount += 1
	end

	local freeBitSpace = #freeBits

	components[name] = {
		_bitPosition = if freeBitSpace > 0 then table.remove(freeBits) :: number else nextBitPos,
		EntityValues = {},
		_template = if valueType == "Instance" then nil else value
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

	local component = components[name]
	local bitPos = component._bitPosition

	for i, v in entityList do
		entityList[i].Components = bit32.replace(v.Components, 0, bitPos)
	end

	for i in component.EntityValues do
		componentValueList[i][bitPos] = nil
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

	entity.Components = bit32.replace(entity.Components, 0, comp._bitPosition)
	comp.EntityValues[id] = nil
	componentValueList[id][comp._bitPosition] = nil
	entity.ComponentRemoved:Fire(name)

end

--[=[
	Gives the component to the given entity, returns the component. If the component
	was created with a default value of type Instance then the default value will
	be nil if not given an Instance in the defaultInstance parameter. Providing a
	value to the parameter on a component that isn't an Instance based component will
	cause the parameter to be ignored.

	@param id number -- ID of Entity
	@param name string -- Name of component to give
	@param defaultInstance -- Default value for instance based components
	@return Component<T>
]=]
function ECS.GiveComponent<T>(id: number, name: string, defaultInstance: Instance?) : Component<T>

	local comp = components[name]
	local entity = entityList[id]
	local newSignal = signal.new()
	local userdata = newproxy(true)
	local mt = getmetatable(userdata)
	local pos = comp._bitPosition
	local template = comp._template

	componentValueList[id] = componentValueList[id] or {}
	componentValueList[id][pos] = if template ~= nil then template else defaultInstance

	mt.__index = function(_, k)
		if k == "ComponentChanged" then return newSignal
		elseif k == "Value" then return componentValueList[id][pos]
		else error("Attempted to index a non existing key", 2) end
	end

	if template ~= nil then
		mt.__newindex = function(_, k: string, v)
			if k == "Value" then
				componentValueList[id][pos] = v
				newSignal:Fire(v)
			else
				error("Attempted to change a non existing key", 2)
			end
		end
	else
		mt.__newindex = function(_, k: string, v)
			if k == "Value" then
				if typeof(v) == "Instance" then
					componentValueList[id][pos] = v
					newSignal:Fire(v)
				else
					error("Assigned value must be of Instance type", 2)
				end
			else
				error("Attempted to change a non existing key", 2)
			end
		end
	end

	entity.Components = bit32.replace(entityList[id].Components, 1, comp._bitPosition)
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
	return bit32.extract(entityList[id].Components, components[name]._bitPosition) == 1
end

return ECS