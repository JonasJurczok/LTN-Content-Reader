for i, force in pairs(game.forces) do 
  force.reset_recipes()
  force.reset_technologies()
  
  if force.technologies["circuit-network"].researched then
    force.recipes["ltn-provider-reader"].enabled = true
    force.recipes["ltn-requester-reader"].enabled = true
  else
    force.recipes["ltn-provider-reader"].enabled = false
    force.recipes["ltn-requester-reader"].enabled = false
  end
end