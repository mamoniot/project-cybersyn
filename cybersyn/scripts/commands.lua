local function fix_priorities_command()
    -- don't depend on any 'storage' data for a repair command

    -- only stops with the same name as a cybersyn stop need to have their priorities reset
    local cybersyn_names = {}
    for _,s in pairs(game.surfaces) do
        for _,ts in pairs(s.find_entities_filtered {name="train-stop"}) do
            if next(s.find_entities_filtered {name="cybersyn-combinator", position=ts.position, radius=3}) then
                cybersyn_names[ts.backer_name] = true
            end
        end
    end

    for _,s in pairs(game.surfaces) do
        for _,ts in pairs(s.find_entities_filtered {name="train-stop"}) do
            if ts.train_stop_priority ~= 50 and cybersyn_names[ts.backer_name] then
                ts.train_stop_priority = 50
                game.print("Reset [train-stop="..ts.unit_number.."] to priority 50")
            end
        end
    end
end

commands.add_command("cybersyn-fix-priorities", {"cybersyn-messages.fix-priorities-command-help"}, fix_priorities_command)
