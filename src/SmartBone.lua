--[[ SmartBone Version 0.2.0 by Angi / ASmartBone modernization based on Celnak's 0.1.2 ]] --

-- // Types \\ --

type func = () -> ()
type dictionary = { [string]: any }
type array = { [number]: any }

type rootList = {
	[number]: Bone
}
type particle = {
	Bone: Bone,
	RestLength: number,
	Weight: number,
	ParentIndex: number,
	Transform: CFrame,
	LocalTransform: CFrame,
	RootTransform: CFrame,
	Radius: number,
	IsColliding: boolean,
	BoneLength: number,
	HeirarchyLength: number,
	DebugPart: BasePart,

	TransformOffset: CFrame,
	LastTransformOffset: CFrame,
	LocalTransformOffset: CFrame,
	RestPosition: Vector3,
	BoneTransform: CFrame,
	CalculatedWorldCFrame: CFrame,
	CalculatedWorldPosition: Vector3,

	Position: Vector3,
	LastPosition: Vector3,
	Anchored: boolean,
	RecyclingBin: any,
}
type particleArray = {
	[number]: particle
}
type particleTree = {
	WindOffset: number,
	Root: Bone,
	RootPart: BasePart,
	RootWorldToLocal: CFrame,
	BoneTotalLength: number,
	Particles: particleArray,
	LocalCFrame: CFrame,
	LocalGravity: Vector3,
	Force: Vector3,
	RestGravity: Vector3,
	ObjectMove: Vector3,
	ObjectPreviousPosition: Vector3,
}

-- // Services \\ --

local Lighting = game:GetService("Lighting")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

if not RunService:IsClient() then 
	warn("Attempted to initialize SmartBone on Server.") 
	return nil
end

-- // Constructors \\ --

local ZERO = Vector3.zero
local GENERATED_TAIL_ATTRIBUTE = "ASmartBoneGeneratedTail"
local MAX_SUBSTEPS = 4
local MAX_SUBSTEP_DELTA = 0.25

-- // Dependencies \\ --

local Dependencies = script:WaitForChild("Dependencies")
local Components = script:WaitForChild("Components")

local Config = require(Dependencies.Config)

local UnitConversion = require(Dependencies.UnitConversion)
local DefaultSettings = require(Dependencies.DefaultSettings)

local ParticleTree = require(Components.ParticleTree)
local Particle = require(Components.Particle)

local SettingsMath = require(Dependencies.SettingsMath)
local Utilities = require(Dependencies.Utilities)

local ID_SEED = 12098135901304
local ID_RANDOM = Random.new(ID_SEED)

local SmartBoneTags = CollectionService:GetTagged("SmartBone")

-- // Debug \\ --

local DEBUG = Config.Debug
local DEBUG_FOLDER, DEBUG_HIGHLIGHT

if DEBUG then
	DEBUG_FOLDER = Instance.new("Model")
	DEBUG_FOLDER.Name = "SMARTBONE_DEBUGFOLDER"
	DEBUG_FOLDER.Parent = workspace

	DEBUG_HIGHLIGHT = Instance.new("Highlight")
	DEBUG_HIGHLIGHT.FillColor = Color3.fromRGB(255, 0, 0)
	DEBUG_HIGHLIGHT.OutlineTransparency = 1
	DEBUG_HIGHLIGHT.FillTransparency = 0
	DEBUG_HIGHLIGHT.Parent = DEBUG_FOLDER
	DEBUG_HIGHLIGHT.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	DEBUG_HIGHLIGHT.Enabled = true
end

-- // Module \ --

local CurrentControllers = {}
local module = {}
module.__index = module

function module.new(rootPart: BasePart, rootList: array)
	local self = setmetatable({
		ID = ID_RANDOM:NextInteger(1, 10000000),
		RootPart = rootPart,
		Time = 0,
		ParticleTrees = {},
		Connections = {},
		RootList = rootList,
		ObjectScale = UnitConversion.Convert(math.abs(rootPart.Size.X), "Millimeter"),
		WindPreviousPosition = Vector3.zero,
		Removed = false,
		RemovedEvent = Instance.new("BindableEvent"),
		InRange = false,

		Settings = {},
	}, module)

	for name, value in DefaultSettings do
		local attributeValue = rootPart:GetAttribute(name)
		self.Settings[name] = attributeValue ~= nil and attributeValue or value
	end

	self.Settings.BlendWeight = 1
	self.Settings.UpdateRate = math.floor(self.Settings.UpdateRate + 0.1)

	self:Init()

	self:UpdateParameters(self.Settings)

	return self
end

function module:Init()
	local RootPart = self.RootPart

	local tailBone, start

	CurrentControllers[self.ID] = self

	self.Connections["AttributeChanged"] = RootPart.AttributeChanged:ConnectParallel(function(Attribute: string)
		if self.Settings[Attribute] == nil then return end
		local value = RootPart:GetAttribute(Attribute)
		self:UpdateParameters(Attribute, value)
	end)

	self.Connections["LightingAttributeChanged"] = Lighting.AttributeChanged:ConnectParallel(function(Attribute: string)
		if self.Settings[Attribute] == nil then return end
		local value = Lighting:GetAttribute(Attribute)
		self:UpdateParameters(Attribute, value)
	end)

	-- Remove synthetic tail bones from a previous initialization before rebuilding the tree.
	for _, descendant in RootPart:GetDescendants() do
		if descendant:IsA("Bone") and descendant:GetAttribute(GENERATED_TAIL_ATTRIBUTE) == true then
			descendant:Destroy()
		end
	end

	for _, Bone in RootPart:GetDescendants() do
		if Bone:IsA("Bone") and Bone.Parent:IsA("Bone") then
			local hasBoneChild = false
			for _, child in Bone:GetChildren() do
				if child:IsA("Bone") then
					hasBoneChild = true
					break
				end
			end

			if not hasBoneChild then
				start = Bone.WorldCFrame
					+ (Bone.WorldCFrame.UpVector.Unit * (Bone.WorldPosition - Bone.Parent.WorldPosition).Magnitude)
				tailBone = Instance.new("Bone")
				tailBone.Parent = Bone
				tailBone.Name = Bone.Name .. "_Tail"
				tailBone:SetAttribute(GENERATED_TAIL_ATTRIBUTE, true)
				tailBone.WorldCFrame = start
			end
		end
	end

	for _, Root in self.RootList do
		self:AppendParticleTree(Root)
	end

	for _, particleTree in self.ParticleTrees do
		self:AppendParticles(particleTree, particleTree.Root, 0, 0)
	end
end

function module:AppendParticleTree(Root: Bone)
	table.insert(self.ParticleTrees, ParticleTree.new(Root, self.RootPart, self.Settings.Gravity))
end

function module:AppendParticles(particleTree: dictionary, Bone: Bone, ParentIndex: number, BoneLength: number)
	local Settings = self.Settings

	local particle: particle = Particle.new(Bone, particleTree.Root, self.RootPart, Settings)
	particle.Position, particle.LastPosition = Bone.WorldPosition, Bone.WorldPosition
	particle.ParentIndex = ParentIndex
	particle.BoneLength = BoneLength
	particle.HeirarchyLength = 0
	if DEBUG == true then
		particle.DebugPart = Instance.new("Part")
		particle.DebugPart.Size = Vector3.new(.1,.1,.1)
		particle.DebugPart.Anchored = true
		particle.DebugPart.CanCollide = false
		particle.DebugPart.CastShadow = false
		particle.DebugPart.CanTouch = false
		particle.DebugPart.CanQuery = false
		particle.DebugPart.Color = Color3.fromRGB(255,0,0)
		particle.DebugPart.Parent = DEBUG_FOLDER
	end
	if ParentIndex >= 1 then
		BoneLength = (particleTree.Particles[ParentIndex].Bone.WorldPosition - particle.Position).Magnitude
		particle.BoneLength = BoneLength
		particle.Weight = (BoneLength * 0.7)
		particle.HeirarchyLength = Utilities.GetHierarchyLength(Bone, particleTree.Root)
	end

	if particle.HeirarchyLength <= Settings.AnchorDepth then
		particle.Anchored = true
	end

	table.insert(particleTree.Particles, particle)

	local index = #particleTree.Particles
	local boneChildren = Bone:GetChildren()

	local child

	for i = 1, #boneChildren do
		child = boneChildren[i]
		if child:IsA("Bone") then
			self:AppendParticles(particleTree, child, index, BoneLength)
		end
	end
end

function module:UpdateParameters(setting, value)
	if DefaultSettings[setting] == nil then return end
	value = value ~= nil and value or DefaultSettings[setting]
	self.Settings[setting] = if SettingsMath[setting] then SettingsMath[setting](value) else value
end

function module:PreUpdate(particleTree: particleTree)
	
	local rootPart = particleTree.RootPart
	local root = particleTree.Root
	
	particleTree.ObjectMove = (rootPart.Position - particleTree.ObjectPreviousPosition)
	particleTree.ObjectPreviousPosition = rootPart.Position

	particleTree.RestGravity = root.WorldCFrame:VectorToWorldSpace(particleTree.LocalGravity)

	for _, particle in particleTree.Particles do
		particle.LastTransformOffset = particle.TransformOffset
		if particle.Bone == particle.Root then
			particle.TransformOffset = rootPart.CFrame * particle.RootTransform
		else
			particle.TransformOffset = root.WorldCFrame * particle.Transform
		end
		particle.LocalTransformOffset = root.CFrame * particle.LocalTransform
	end
end

function module:UpdateParticles(particleTree: particleTree, Delta: number, LoopIndex: number)
	local Settings = self.Settings

	local Damping = Settings.Damping
	local Force = Settings.Gravity
	local ForceDirection = Settings.Gravity.Magnitude > 0 and Settings.Gravity.Unit or ZERO

	local ProjectedForce = Settings.Gravity.Magnitude > 0
		and ForceDirection * math.max(particleTree.RestGravity:Dot(ForceDirection), 0)
		or ZERO

	Force -= ProjectedForce
	Force = (Force + Settings.Force) * (self.ObjectScale * Delta)

	local ObjectMove = LoopIndex == 0 and particleTree.ObjectMove or ZERO

	local windMove, velocity, move
	local timeModifier

	for _, particle in particleTree.Particles do
		if particle.ParentIndex >= 1 and particle.Anchored == false then
			windMove = ZERO

			if Settings.WindInfluence > 0 and particle.BoneLength > 0 then
				timeModifier = particleTree.WindOffset
					+ (os.clock() - (particle.HeirarchyLength / 5))
					+ (
						((particle.TransformOffset.Position - particleTree.Root.WorldPosition).Magnitude / 5)
						* Settings.WindInfluence
					)

				windMove = Vector3.new(
					Settings.WindDirection.X
						+ (Settings.WindDirection.X * (math.sin(timeModifier * Settings.WindSpeed))),
					Settings.WindDirection.Y + (0.05 * (math.sin(timeModifier * Settings.WindSpeed))),
					Settings.WindDirection.Z
						+ (Settings.WindDirection.Z * (math.sin(timeModifier * Settings.WindSpeed)))
				)

				windMove /= particle.BoneLength
				windMove *= Settings.WindInfluence
				windMove *= (Settings.WindStrength / 100) * (math.clamp(particle.HeirarchyLength, 1, 10) / 10)
				windMove *= particle.Weight
				self.WindPreviousPosition = windMove
			end

			velocity = (particle.Position - particle.LastPosition)
			move = (ObjectMove * Settings.Inertia)
			
			particle.LastPosition = particle.Position + move
			particle.Position += velocity * (1 - Damping) + Force + move + windMove
		else
			particle.LastPosition = particle.TransformOffset.Position--particle.Bone.WorldPosition
			particle.Position = particle.TransformOffset.Position
		end
	end
end

function module:CorrectParticles(particleTree: particleTree, Delta: number)
	local Settings = self.Settings
	local stiffness = Settings.Stiffness

	local parentPoint
	local restLength, difference, length
	local mat, restPosition, maxLength

	for _, point in particleTree.Particles do
		parentPoint = particleTree.Particles[point.ParentIndex]

		if parentPoint and point.ParentIndex >= 1 and point.Anchored == false then
			restLength = (parentPoint.TransformOffset.Position - point.TransformOffset.Position).Magnitude

			if stiffness > 0 or Settings.Elasticity > 0 then
				mat = CFrame.new(parentPoint.Position) * parentPoint.TransformOffset.Rotation
				restPosition = (mat * CFrame.new(point.LocalTransformOffset.Position)).Position

				difference = restPosition - point.Position
				point.Position += difference * (Settings.Elasticity * Delta)

				if stiffness > 0 then
					difference = restPosition - point.Position
					length = difference.Magnitude
					maxLength = restLength * (1 - stiffness) * 2
					if length > maxLength then
						point.Position += difference * ((length - maxLength) / length)
					end
				end
			end

			difference = parentPoint.Position - point.Position
			length = difference.Magnitude
			if length > 0 then
				point.Position += difference * ((length - restLength) / length)
			end
		end
	end
end

function module:SkipUpdateParticles(particleTree: particleTree)
	local parentPoint, restLength, stiffness
	local restPosition, difference, length, maxLength

	for _, point in particleTree.Particles do
		if point.ParentIndex >= 1 and not point.Anchored then
			point.LastPosition += particleTree.ObjectMove
			point.Position += particleTree.ObjectMove

			parentPoint = particleTree.Particles[point.ParentIndex]
			restLength = (parentPoint.TransformOffset.Position - point.TransformOffset.Position).Magnitude
			stiffness = self.Settings.Stiffness

			if stiffness > 0 then
				restPosition = parentPoint.Position
					+ CFrame.lookAt(parentPoint.Position, point.Position).LookVector.Unit
						* (parentPoint.Position - point.Position).Magnitude

				difference = restPosition - point.Position
				length = difference.Magnitude
				maxLength = restLength * (1 - stiffness) * 2
				if length > maxLength then
					point.Position += difference * ((length - maxLength) / length)
				end
			end

			difference = parentPoint.Position - point.Position
			length = difference.Magnitude
			if length > restLength then
				point.Position += difference * ((length - restLength) / length)
			end
		else
			point.LastPosition = point.TransformOffset.Position--particle.Bone.WorldPosition
			point.Position = point.TransformOffset.Position
		end
	end
end

function module:CalculateTransforms(particleTree: particleTree, Delta: number)
	if self.InRange then
		local parentPoint, boneParent
		local localPosition, referenceCFrame, v0, v1, rotation, factor, alpha

		for _, point in particleTree.Particles do
			if point.ParentIndex >= 1 and point.Anchored == false then
				parentPoint = particleTree.Particles[point.ParentIndex]
				boneParent = parentPoint.Bone

				if parentPoint and boneParent and boneParent:IsA("Bone") and boneParent ~= particleTree.Root then
					localPosition = parentPoint.LocalTransformOffset.Position
					referenceCFrame = parentPoint.TransformOffset
					v0 = referenceCFrame:PointToObjectSpace(localPosition)
					v1 = point.Position - parentPoint.Position
					rotation = Utilities.GetRotationBetween(referenceCFrame.UpVector, v1, v0).Rotation
						* referenceCFrame.Rotation

					factor = 0.00001
					alpha = (1 - factor ^ Delta)

					parentPoint.CalculatedWorldCFrame = boneParent.WorldCFrame:Lerp(CFrame.new(parentPoint.Position) * rotation, alpha)
				end
			end
		end
	end
end

function module:TransformBones(particleTree: particleTree)
	local parentPoint, boneParent

	if self.InRange then
		for _, point in particleTree.Particles do
			if point.ParentIndex >= 1 and point.Anchored == false then
				parentPoint = particleTree.Particles[point.ParentIndex]
				boneParent = parentPoint.Bone

				if parentPoint and boneParent and boneParent:IsA("Bone") and boneParent ~= particleTree.Root then
					if parentPoint.Anchored and self.Settings.AnchorsRotate == false then
						boneParent.WorldCFrame = parentPoint.TransformOffset
					else
						boneParent.WorldCFrame = parentPoint.CalculatedWorldCFrame
					end
				end
			end
		end
	end
end

function module:DEBUG(particleTree: particleTree)
	for _, point in particleTree.Particles do
		if point then
			point.DebugPart.CFrame = CFrame.new(point.Position)
		end
	end
end

function module:RunLoop(particleTree: particleTree, Delta: number, UpdateRate: number)
	local ready = true
	local timeVar = Delta * 10

	if UpdateRate > 0 then
		local frameTime = 1 / UpdateRate
		self.Time += Delta
		ready = false

		if self.Time >= frameTime then
			ready = true
			self.Time = 0
		end
	end

	if ready then
		local substeps = math.min(MAX_SUBSTEPS, math.max(1, math.ceil(timeVar / MAX_SUBSTEP_DELTA)))
		local substepDelta = timeVar / substeps

		for substep = 1, substeps do
			self:UpdateParticles(particleTree, substepDelta, substep == 1 and 0 or 1)
			self:CorrectParticles(particleTree, substepDelta)
		end
	else
		self:SkipUpdateParticles(particleTree)
	end
end

function module:ResetParticles(particleTree: particleTree)
	for _, point in particleTree.Particles do
		point.LastPosition = point.TransformOffset.Position
		point.Position = point.TransformOffset.Position
	end
end

function module:ResetTransforms(particleTree: particleTree)
	local transformOffset

	for _, point in particleTree.Particles do
		if point.Bone == point.Root then
			transformOffset = particleTree.RootPart.CFrame * point.RootTransform
		else
			transformOffset = particleTree.Root.WorldCFrame * point.Transform
		end

		point.Bone.WorldCFrame = transformOffset
	end
end

function module:UpdateBones(Delta: number, UpdateRate: number)
	for _, particleTree: particleTree in self.ParticleTrees do
		self:PreUpdate(particleTree, Delta)
		self:RunLoop(particleTree, Delta, UpdateRate)
		self:CalculateTransforms(particleTree, Delta)
	end
end

function module.Start()
	local Player = game.Players.LocalPlayer

	local ActorsFolder = Instance.new("Folder")
	ActorsFolder.Name = "Actors"
	ActorsFolder.Parent = Player:WaitForChild("PlayerScripts")

	local function DebugPrint(String: string)
		if DEBUG then
			warn(String)
		end
	end

	local SmartBones = {}
	local IgnoreList = {}

	local function registerSmartBoneObject(Object: BasePart)
		if
			Object:IsA("BasePart")
			and Utilities.WaitForChildOfClass(Object, "Bone", 3)
			and game.Workspace:IsAncestorOf(Object)
		then
			local RootList = {}

			if
				Object:GetAttribute("Roots")
				and Object:GetAttribute("Roots") ~= nil
				and typeof(Object:GetAttribute("Roots")) == "string"
			then
				local list = string.split(Object:GetAttribute("Roots"), ",")
				for _, value in ipairs(list) do
					local Bone = Object:FindFirstChild(value, true)
					if Bone and Bone:IsA("Bone") then
						table.insert(RootList, Bone)
					end
				end
			end

			if #RootList > 0 then
				local SmartBoneActor = Instance.new("Actor")

				local Event = Instance.new("BindableFunction")
				Event.Name = "Event"
				Event.Parent = SmartBoneActor

				local RuntimeScript = script.Dependencies.ActorScript:Clone()
				RuntimeScript.Name = "Runtime"
				RuntimeScript.Parent = SmartBoneActor

				SmartBoneActor.Parent = ActorsFolder

				RuntimeScript.Enabled = true

				SmartBones[Object] = SmartBoneActor.Event:Invoke(Object, RootList)

				SmartBoneActor.Name = Object.Name .. SmartBones[Object].ID

				SmartBones[Object].RemovedEvent.Event:Once(function()
					SmartBoneActor.Runtime.Enabled = false
					SmartBoneActor:Destroy()
				end)

				table.insert(IgnoreList, Object)
				DebugPrint("Created new SmartBone Object with ID: " .. SmartBones[Object].ID)
			else
				table.insert(IgnoreList, Object)
				DebugPrint(
					"Failed to create SmartBone Object for "
						.. Object:GetFullName()
						.. "! Make sure you have defined the Root Bone(s) for this object!"
				)
			end
		end
	end

	local function removeSmartBoneObject(Object: BasePart)
		local SBone = SmartBones[Object]
		if not SBone then return end

		DebugPrint("Removing SmartBone Object with ID: " .. SBone.ID)
		SmartBones[Object] = nil

		for _, Connection in pairs(SBone.Connections) do
			Connection:Disconnect()
		end

		if SBone.SimulationConnection then
			SBone.SimulationConnection:Disconnect()
		end

		for _, particleTree: particleTree in ipairs(SBone.ParticleTrees) do
			for _, _Particle in particleTree.Particles do
				if _Particle.DebugPart then
					_Particle.DebugPart:Destroy()
				end

				for _, Recycling in _Particle.RecyclingBin do
					if Recycling then
						Recycling:Destroy()
					end
				end
			end
		end

		-- Synthetic tails are implementation details; never leave them in the rig after removal.
		for _, descendant in SBone.RootPart:GetDescendants() do
			if descendant:IsA("Bone") and descendant:GetAttribute(GENERATED_TAIL_ATTRIBUTE) == true then
				descendant:Destroy()
			end
		end

		CurrentControllers[SBone.ID] = nil
		SBone.Removed = true
		SBone.RemovedEvent:Fire()
		SBone.RemovedEvent:Destroy()
	end

	CollectionService:GetInstanceAddedSignal("SmartBone"):Connect(registerSmartBoneObject)
	CollectionService:GetInstanceRemovedSignal("SmartBone"):Connect(removeSmartBoneObject)

	for _, Object in pairs(SmartBoneTags) do
		if not SmartBones[Object] and not table.find(IgnoreList, Object) then
			task.spawn(function()
				registerSmartBoneObject(Object)
			end)
		end
	end
end

return module
