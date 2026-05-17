--!strict
local RomalECS = require("./RomalECS")
RomalECS.CreateComponent("A", 100)
RomalECS.NewEntity()

local component = RomalECS.GiveComponent(1, "A")

component.ComponentChanged:Connect(function(v) 
    print(v)
end)