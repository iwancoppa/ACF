local UpdateIndex = 0
function ACF_UpdateVisualHealth(Entity)
	if Entity.ACF.PrHealth == Entity.ACF.Health then return end
	if not ACF_HealthUpdateList then
		ACF_HealthUpdateList = {}
		timer.Create("ACF_HealthUpdateList", 1, 1, function() // We should send things slowly to not overload traffic.
			local Table = {}
			for k,v in pairs(ACF_HealthUpdateList) do
				if IsValid( v ) then
					table.insert(Table,{ID = v:EntIndex(), Health = v.ACF.Health, MaxHealth = v.ACF.MaxHealth})
				end
			end
			net.Start("ACF_RenderDamage")
				net.WriteTable(Table)
			net.Broadcast()
			ACF_HealthUpdateList = nil
		end)
	end
	table.insert(ACF_HealthUpdateList, Entity)
end




ACF.ModelProperties = {}
ACF.ModelProperties[""] = {area = 6, volume = 1}	// default for unknown models; a 1cm^3 cube
ACF.BoxProperties = {}
/*
	Uses an instance of a model to calculate statistics and caches within ACF.ModelProperties
	All subsequent props can then use this info to avoid giant explosion lag.
	Args;
		Entity	Entity:	The sample entity.
//*/
function ACF_GenerateModelProperties(Entity, model)
	local PhysObj = Entity:GetPhysicsObject()
	model = model or Entity:GetModel()
	local mdlprops
	
	if PhysObj:IsValid() then
		mdlprops = {}
		mdlprops.area = PhysObj:GetSurfaceArea() * 6.45 * 0.52505066107 //(PhysObj:GetSurfaceArea() * 6.45) * 0.52505066107
		mdlprops.volume = PhysObj:GetVolume() * 16.387
		local obb = Entity:OBBMaxs() - Entity:OBBMins()
		local obbarea = (obb.x * obb.y + obb.x * obb.z + obb.y * obb.z) * 6.45 
		mdlprops.surfratio = mdlprops.area / obbarea

		if mdlprops.area > 0 and mdlprops.volume > 0 then
			ACF.ModelProperties[model] = mdlprops
			if ACF.BoxProperties[model] then
				ACF.BoxProperties[model] = nil
			end
			
			return mdlprops
		end
	end
	
	mdlprops = ACF.BoxProperties[model]
	if not mdlprops then
		mdlprops = {}
		local Size = Entity:OBBMaxs() - Entity:OBBMins()
		mdlprops.area = (Size.x * Size.y + Size.x * Size.z + Size.y * Size.z) * 6.45 
		mdlprops.volume = Size.x * Size.y * Size.z * 16.387
		mdlprops.surfratio = 1
		ACF.BoxProperties[model] = mdlprops
		return mdlprops
	end
	
	return mdlprops
end




function ACF_Activate ( Entity , Recalc )

	--Density of steel = 7.8g cm3 so 7.8kg for a 1mx1m plate 1m thick
	if Entity.SpecialHealth then
		Entity:ACF_Activate( Recalc )
		return
	end
	Entity.ACF = Entity.ACF or {} 
	local entacf = Entity.ACF
	
	local model = Entity:GetModel()
	local mdlprops = ACF.ModelProperties[model or ""]
	
	if not mdlprops then
		mdlprops = ACF_GenerateModelProperties(Entity, model)
	end
	
	local area, volume = mdlprops.area, mdlprops.volume
	local mass = Entity:GetPhysicsObject():GetMass()
	
	entacf.Aera = area
	entacf.Volume = volume
	entacf.Density = (mass * 1000) / volume
	
	entacf.Ductility = entacf.Ductility or 0
	local Area = area + area * math.Clamp(entacf.Ductility, -0.8, 0.8)
	local Armour = mdlprops.surfratio * mass * 1000 / (Area * 0.78) 		--So we get the equivalent thickness of that prop in mm if all it's weight was a steel plate
	local Health = Area/ACF.Threshold												--Setting the threshold of the prop aera gone
	
	if Recalc and entacf.Health and entacf.MaxHealth then
		local Fraction = entacf.Health/entacf.MaxHealth
		
		entacf.Health = Health * Fraction
		entacf.MaxHealth = Health
		entacf.Armour = Armour * (0.5 + Fraction/2)
		entacf.MaxArmour = Armour * ACF.ArmorMod
		entacf.Type = nil
		entacf.Mass = mass
	else	
		entacf.Health = Health
		entacf.MaxHealth = Health
		entacf.Armour = Armour
		entacf.MaxArmour = Armour * ACF.ArmorMod
		entacf.Type = nil
		entacf.Mass = mass
	end
	
	if Entity:IsPlayer() or Entity:IsNPC() then
		entacf.Type = "Squishy"
	elseif Entity:IsVehicle() then
		entacf.Type = "Vehicle"
	else
		entacf.Type = "Prop"
	end
	
end




function ACF_Check ( Entity )
	
	if ( IsValid(Entity) ) then
		if ( Entity:GetPhysicsObject():IsValid() and !Entity:IsWorld() and !Entity:IsWeapon() ) then
			local Class = Entity:GetClass()
			if ( Class != "gmod_ghost" and Class != "debris" and Class != "prop_ragdoll" and not string.find( Class , "func_" )  ) then
				if !Entity.ACF then 
					ACF_Activate( Entity )
				elseif Entity.ACF.Mass != Entity:GetPhysicsObject():GetMass() then
					ACF_Activate( Entity , true )
				end
				--print("ACF_Check "..Entity.ACF.Type)
				return Entity.ACF.Type	
			end	
		end
	end
	return false
	
end


local zeroHitres = { Damage = 0, Overkill = 0, Loss = 0, Kill = false }
function ACF_Damage ( Entity , Energy , FrAera , Angle , Inflictor , Bone, Gun ) 
	
	local Activated = ACF_Check( Entity )
	local CanDo = hook.Run("ACF_BulletDamage", Activated, Entity, Energy, FrAera, Angle, Inflictor, Bone, Gun )
	if CanDo == false then
		return zeroHitres
	end
	
	if Entity.SpecialDamage then
		return Entity:ACF_OnDamage( Entity , Energy , FrAera , Angle , Inflictor , Bone )
	elseif Activated == "Prop" then	
		
		return ACF_PropDamage( Entity , Energy , FrAera , Angle , Inflictor , Bone )
		
	elseif Activated == "Vehicle" then
	
		return ACF_VehicleDamage( Entity , Energy , FrAera , Angle , Inflictor , Bone, Gun )
		
	elseif Activated == "Squishy" then
	
		return ACF_SquishyDamage( Entity , Energy , FrAera , Angle , Inflictor , Bone, Gun )
		
	end
	
end

function ACF_CalcDamage( Entity , Energy , FrAera , Angle )

	local Armour = Entity.ACF.Armour/math.abs( math.cos(math.rad(Angle)) ) --Calculate Line Of Sight thickness of the armour
	local Structure = Entity.ACF.Density --Structural strengh of the material, derived from prop density, denser stuff is more vulnerable (Density is different than armour, calculated off real volume)
	
	local MaxPenetration = (Energy.Penetration / FrAera) * ACF.KEtoRHA							--Let's see how deep the projectile penetrates ( Energy = Kinetic Energy, FrAera = Frontal aera in cm2 )
	--print(MaxPenetration)
	local Penetration = math.min( MaxPenetration , Armour )			--Clamp penetration to the armour thickness
	
	local HitRes = {}
	--BNK Stuff
	local dmul = 1
	if (ISBNK) then
		local cvar = GetConVarNumber("sbox_godmode")
	
		if (cvar == 1) then
			dmul = 0
		end
	end
	--SITP Stuff
	local var = 1
	if (ISSITP) then
		if(!Entity.sitp_spacetype) then
			Entity.sitp_spacetype = "space"
		end
		if(Entity.sitp_spacetype != "space" and Entity.sitp_spacetype != "planet") then
			var = 0
		end
	end
	
	HitRes.Damage = var * dmul * (Penetration/Armour)^2 * FrAera	-- This is the volume of the hole caused by our projectile 
	--print("ACF_CalcDamage Damage "..HitRes.Damage)
	HitRes.Overkill = (MaxPenetration - Penetration)
	HitRes.Loss = Penetration/MaxPenetration
	
	return HitRes
end

function ACF_PropDamage( Entity , Energy , FrAera , Angle , Inflictor , Bone )

	local HitRes = ACF_CalcDamage( Entity , Energy , FrAera , Angle )
	
	HitRes.Kill = false
	if HitRes.Damage >= Entity.ACF.Health then
		HitRes.Kill = true 
	else
		Entity.ACF.Health = Entity.ACF.Health - HitRes.Damage
		Entity.ACF.Armour = Entity.ACF.MaxArmour * (0.5 + Entity.ACF.Health/Entity.ACF.MaxHealth/2) --Simulating the plate weakening after a hit
		
		if Entity.ACF.PrHealth then
			ACF_UpdateVisualHealth(Entity)
		end
		Entity.ACF.PrHealth = Entity.ACF.Health
	end
	
	return HitRes
	
end

function ACF_VehicleDamage( Entity , Energy , FrAera , Angle , Inflictor , Bone, Gun )

	local HitRes = ACF_CalcDamage( Entity , Energy , FrAera , Angle )
	
	local Driver = Entity:GetDriver()
	if Driver:IsValid() then
		--if Ammo == true then
		--	Driver.KilledByAmmo = true
		--end
		Driver:TakeDamage( HitRes.Damage*40 , Inflictor, Gun )
		--if Ammo == true then
		--	Driver.KilledByAmmo = false
		--end
		
	end

	HitRes.Kill = false
	if HitRes.Damage >= Entity.ACF.Health then
		HitRes.Kill = true 
	else
		Entity.ACF.Health = Entity.ACF.Health - HitRes.Damage
		Entity.ACF.Armour = Entity.ACF.Armour * (0.5 + Entity.ACF.Health/Entity.ACF.MaxHealth/2) --Simulating the plate weakening after a hit
	end
		
	return HitRes
end

function ACF_SquishyDamage( Entity , Energy , FrAera , Angle , Inflictor , Bone, Gun)
	
	local Size = Entity:BoundingRadius()
	local Mass = Entity:GetPhysicsObject():GetMass()
	local HitRes = {}
	local Damage = 0
	local Target = {ACF = {Armour = 0.1}}		--We create a dummy table to pass armour values to the calc function
	if (Bone) then
		
		if ( Bone == 1 ) then		--This means we hit the head
			Target.ACF.Armour = Mass*0.02	--Set the skull thickness as a percentage of Squishy weight, this gives us 2mm for a player, about 22mm for an Antlion Guard. Seems about right
			HitRes = ACF_CalcDamage( Target , Energy , FrAera , Angle )		--This is hard bone, so still sensitive to impact angle
			Damage = HitRes.Damage*20
			if HitRes.Overkill > 0 then									--If we manage to penetrate the skull, then MASSIVE DAMAGE
				Target.ACF.Armour = Size*0.25*0.01						--A quarter the bounding radius seems about right for most critters head size
				HitRes = ACF_CalcDamage( Target , Energy , FrAera , 0 )
				Damage = Damage + HitRes.Damage*100
			end
			Target.ACF.Armour = Mass*0.065	--Then to check if we can get out of the other side, 2x skull + 1x brains
			HitRes = ACF_CalcDamage( Target , Energy , FrAera , Angle )	
			Damage = Damage + HitRes.Damage*20				
			
		elseif ( Bone == 0 or Bone == 2 or Bone == 3 ) then		--This means we hit the torso. We are assuming body armour/tough exoskeleton/zombie don't give fuck here, so it's tough
			Target.ACF.Armour = Mass*0.08	--Set the armour thickness as a percentage of Squishy weight, this gives us 8mm for a player, about 90mm for an Antlion Guard. Seems about right
			HitRes = ACF_CalcDamage( Target , Energy , FrAera , Angle )		--Armour plate,, so sensitive to impact angle
			Damage = HitRes.Damage*5
			if HitRes.Overkill > 0 then
				Target.ACF.Armour = Size*0.5*0.02							--Half the bounding radius seems about right for most critters torso size
				HitRes = ACF_CalcDamage( Target , Energy , FrAera , 0 )		
				Damage = Damage + HitRes.Damage*50							--If we penetrate the armour then we get into the important bits inside, so DAMAGE
			end
			Target.ACF.Armour = Mass*0.185	--Then to check if we can get out of the other side, 2x armour + 1x guts
			HitRes = ACF_CalcDamage( Target , Energy , FrAera , Angle )
			
		elseif ( Bone == 4 or Bone == 5 ) then 		--This means we hit an arm or appendage, so ormal damage, no armour
		
			Target.ACF.Armour = Size*0.2*0.02							--A fitht the bounding radius seems about right for most critters appendages
			HitRes = ACF_CalcDamage( Target , Energy , FrAera , 0 )		--This is flesh, angle doesn't matter
			Damage = HitRes.Damage*30							--Limbs are somewhat less important
		
		elseif ( Bone == 6 or Bone == 7 ) then
		
			Target.ACF.Armour = Size*0.2*0.02							--A fitht the bounding radius seems about right for most critters appendages
			HitRes = ACF_CalcDamage( Target , Energy , FrAera , 0 )		--This is flesh, angle doesn't matter
			Damage = HitRes.Damage*30							--Limbs are somewhat less important
			
		elseif ( Bone == 10 ) then					--This means we hit a backpack or something
		
			Target.ACF.Armour = Size*0.1*0.02							--Arbitrary size, most of the gear carried is pretty small
			HitRes = ACF_CalcDamage( Target , Energy , FrAera , 0 )		--This is random junk, angle doesn't matter
			Damage = HitRes.Damage*2								--Damage is going to be fright and shrapnel, nothing much		

		else 										--Just in case we hit something not standard
		
			Target.ACF.Armour = Size*0.2*0.02						
			HitRes = ACF_CalcDamage( Target , Energy , FrAera , 0 )
			Damage = HitRes.Damage*30	
			
		end
		
	else 										--Just in case we hit something not standard
	
		Target.ACF.Armour = Size*0.2*0.02						
		HitRes = ACF_CalcDamage( Target , Energy , FrAera , 0 )
		Damage = HitRes.Damage*10	
	
	end
	
	local dmul = 2.5
	
	--BNK stuff
	if (ISBNK) then
		if(Entity.freq and Inflictor.freq) then
			if (Entity != Inflictor) and (Entity.freq == Inflictor.freq) then
				dmul = 0
			end
		end
	end
	
	--SITP stuff
	local var = 1
	if(!Entity.sitp_spacetype) then
		Entity.sitp_spacetype = "space"
	end
	if(Entity.sitp_spacetype == "homeworld") then
		var = 0
	end
	
	--if Ammo == true then
	--	Entity.KilledByAmmo = true
	--end
	Entity:TakeDamage( Damage * dmul * var, Inflictor, Gun )
	--if Ammo == true then
	--	Entity.KilledByAmmo = false
	--end
	
	HitRes.Kill = false
	--print(Damage)
	--print(Bone)
		
	return HitRes
end

----------------------------------------------------------
-- Returns a table of all physically connected entities
-- ignoring ents attached by only nocollides
----------------------------------------------------------
function ACF_GetAllPhysicalConstraints( ent, ResultTable )

	local ResultTable = ResultTable or {}
	
	if not IsValid( ent ) then return end
	if ResultTable[ ent ] then return end
	
	ResultTable[ ent ] = ent
	
	local ConTable = constraint.GetTable( ent )
	
	for k, con in ipairs( ConTable ) do
		
		-- skip shit that is attached by a nocollide
		if con.Type == "NoCollide" then continue end
		
		for EntNum, Ent in pairs( con.Entity ) do
			ACF_GetAllPhysicalConstraints( Ent.Entity, ResultTable )
		end
	
	end

	return ResultTable
	
end