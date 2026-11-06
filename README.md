# Project Cybersyn

Behold one of the most feature-rich and performant train logistics network mods Factorio has to offer. Named for [Project Cybersyn](https://en.wikipedia.org//wiki/Project_Cybersyn) of Allende's Chile, with just this mod you can coordinate the economic inputs and outputs of your entire megabase. Similar in functionality to the famous Logistics Train Network mod, but with a much broader scope.

[Join our discord!](https://discord.gg/zmgUBu95HX) This is the preferred place for players to report bugs, make suggestions, or keep up with development.

![Image](https://raw.githubusercontent.com/mamoniot/project-cybersyn/main/previews/outpost-resupply-station.png)


## [Project Cybersyn Official Example Blueprints](https://raw.githubusercontent.com/mamoniot/project-cybersyn/main/cybersyn_blueprints.txt)
Copy the contents of https://raw.githubusercontent.com/mamoniot/project-cybersyn/main/cybersyn_blueprints.txt and paste them into the import string text box to see examples of how to create a functional network. I highly recommend taking a look at these; the blueprint book showcases both the basics of the mod and highly advanced designs you can create.

## Quick Start Guide

Within Project Cybersyn, you can think of requester stations as requester chests, provider stations as passive provider chests, depots as roboports and trains as the logistics bots. There is a direct correspondence between the Cybersyn train network and Factorio's robot logistics network.

A bare minimum Cybersyn train network consists of 2 components: depots and stations. Both are created by placing a cybernetic combinator adjacent to a train stop. Select the "Mode" of the combinator to "Station" to create a station, and to "Depot" to create a depot. Create a basic train and order it to park at the depot you just created, it is now controlled by the Cybersyn network. Depots and stations can have any train stop name, names do not impact their function. The circuit network input of a station's cybernetic combinator determines what cargo, as in items or fluids, that station will request or provide to the Cybersyn network. A positive cargo signal is interpreted as that station providing that cargo to the network; A negative cargo signal is interpreted as that station requesting that cargo from the network.

To make a basic provider station, create a cargo buffer of chests or tanks adjacent to the station's tracks, and connect that buffer by wire to the input of the cybernetic combinator. To make a basic requester station, repeat the same, except reverse the direction of the inserters or pumps so they are *unloading* instead of loading; then connect a constant combinator to the same circuit network, set it to output the number of cargo you want this requester station to keep loaded in its cargo buffer, and flip the sign of each so the signal strength is negative. Then add the signal called "Request threshold" to the constant combinator. Set its signal strength to be at most the cargo capacity of the trains in your system. Once the provider station contains the cargo being requested, a train will automatically be sent to deliver that cargo from the provider station to the requester station. The requester station's buffer will automatically be topped up on the cargo being requested. Be sure that the requester station has the space to at minimum unload 2 fully loaded trains.

Follow the above directions and you have set up a bare minimum Cybersyn network! You may continue adding onto it with more stations and depots and Cybersyn will automatically manage all of them for you. There is one issue with this kind of network though; trains won't always deliver full loads of cargo, meaning trains will make deliveries more frequently than is necessary. To fix this issue you will need to start using "request thresholds". To get a full picture of how request thresholds work, either import the official example blueprints from above, or read the **Request thresholds** section below.

Open the [Cybersyn Manager](#cybersyn-manager) with Ctrl+T to see what your network is doing and why a request is still waiting.

## Features

![Image](https://raw.githubusercontent.com/mamoniot/project-cybersyn/main/previews/gui-modes.png)

**Minimalistic and intuitively designed**, without sacrificing features. Configure your stations using just 3 virtual signals, a couple of combinator settings and the train stop's own train limit.

### A whole suite of new and optional circuit network inputs and outputs to control your stations precisely
* Natively read out all deliveries currently in progress for a station, not just the loading or unloading orders of the parked train.
* Set request thresholds per cargo instead of just for the entire station.
* Read out cargo loading or unloading orders per train wagon, instead of just for the entire train.
* Set item filters per cargo wagon, making multi-item deliveries very easy.
* Provide or request several inventories from one train stop, each with its own network mask, priority and thresholds.

![Image](https://raw.githubusercontent.com/mamoniot/project-cybersyn/main/previews/universal-station.png)

These all combine to make it possible to **create "universal" stations**; stations that provide any arbitrary number of different items for a train of any arbitrary length! Build stations that supply you all items from your mall, stations that grab selected items from your disorganized storage chests, or stations that transfer any item between two otherwise completely distinct networks!

![Image](https://raw.githubusercontent.com/mamoniot/project-cybersyn/main/previews/gui-allow-list.png)

Stations can **automatically build allow-lists for trains** they can load or unload. Inserters or pumps adjacent to the station's tracks are auto-detected. No more deadlocks caused by trains mistakenly attempting to fulfill a delivery to a station that cannot unload it. This feature is compatible with miniloaders.

Trains can automatically visit **centralized refuelers**. It is not required that every single depot loads trains with fuel.

Trains can **bypass visiting the depot** if they have enough fuel. Trains spend far more time productively making deliveries rather than travelling to and from their depot. Fewer reserve trains are needed as a result.

**Easy and versatile ways to define separate train networks.** Bitwise network masks are now optional! Networks are identified by signal id first, then by signal strength.

![Image](https://raw.githubusercontent.com/mamoniot/project-cybersyn/main/previews/fault-alert.png)

**Improved fault handling.** Mistakes and misconfigured stations are unlikely to result in cargo being delivered to places they shouldn't, and the player will be alerted immediately about the fault.

![Image](https://raw.githubusercontent.com/mamoniot/project-cybersyn/main/previews/manager/overview.png)

**Find out why a request is still waiting.** The central planner records a reason every time it cannot serve a request, such as no provider, provider low, network mask, no free train or train too small, and setup checks flag misconfigured stops before they cost a delivery. The [Cybersyn Manager](#cybersyn-manager) shows both, along with every station, train and item on your network.

Runs a custom, **highly optimized central planning algorithm**, resulting in exceptionally good performance, see https://forums.factorio.com/viewtopic.php?p=580024#p580024. This allows the station update rate to be twice that of LTN by default, resulting in more responsive dispatching, especially on larger bases. The Cybersyn Manager and its diagnostics are built to stay out of the way: the manager costs next to nothing while no window is open and the diagnostics are bounded, see [Performance](#performance).

![Image](https://raw.githubusercontent.com/mamoniot/project-cybersyn/main/previews/se-compat.png)

**Native space exploration compatibility!** Without any trouble this mod will automatically detect any space elevator on the planet and add it to the orders of trains which want to travel between surfaces. Unless there is a space elevator connecting the surfaces, each surface must be set to its own network.

Built from the ground up to be **free and open source forever**. *¡Viva la Revolución!*

Custom art and models to come in future updates!

I'm accepting submissions for localizations/translations. If you can speak a non-English language, feel free to submit a pull request on my github for a new locale file. If you don't know how to do that, message me however you would like, such as a discussion thread on the mod portal, and I will walk you through how to create a translation for this mod.

If you like my work, consider supporting me on [ko-fi](https://ko-fi.com/lesbianmami).

## Mod Details

This mod adds a single new entity to the game, the cybernetic combinator. This combinator can be in one of 6 different possible modes. While each mode has a purpose, the only modes you are required to use are station mode and depot mode.

### Station mode

![Image](https://raw.githubusercontent.com/mamoniot/project-cybersyn/main/previews/multi-item.png)

When placed adjacent to a vanilla train stop, a Cybersyn station is created. This station can provide or request cargo to your train network. Connect the input of the combinator to a circuit network; When a positive cargo signal is received, this station will provide that cargo to the network, when a negative signal is received, this station will request that cargo from the network. When a station is providing a type of cargo that another station is requesting, a train order will automatically be generated to transfer that cargo from the providing station to the requesting station. When a train arrives to fulfill this order, the output of the combinator will give the full list of cargo expected to be loaded (negative) or unloaded (positive) from the train.

Stations can automatically build allow-lists. When this option is enabled, only trains that can be loaded or unloaded by this station will be allowed to make deliveries to it. Stations determine this based on what inserters or pumps are present at this station along its tracks. When disabled, all trains within the network are allowed.

Stations can be set to provide only or request only. By default stations can both provide and request, but when one of these options is chosen either requesting is disabled or providing is disabled.

### Depot mode

![Image](https://raw.githubusercontent.com/mamoniot/project-cybersyn/main/previews/big-depot.png)

When placed adjacent to a vanilla train stop, a Cybersyn depot is created. Any train which parks at this depot will automatically be added to the train network. Whenever a train order is generated, if this train has the cargo capacity to fulfill it, and is allow-listed by both stations, then it will automatically be dispatched to fulfill the order. When the order is completed, the train will return to any train stop with the same name as the depot it first parked in. This almost always means it returns to a Cybersyn depot where it will again await to fulfill a new order. To save on UPS the input of a depot combinator is only read when a train parks at the depot; this is only relevant for networks which make extensive use of network masks on depots.

### Refueler mode

When placed adjacent to a vanilla train stop, a Cybersyn refueler is created. Whenever a train completes a delivery, if it is running low on fuel (configurable in mod settings), it will attempt to visit a refueler before returning to the depot. The train will search for a refueler within its network that has not exceeded its train limit and that it is allow-listed for. If one is found it will schedule a detour to it to stock back up on fuel.

Refuelers can automatically build allow-lists. When this option is enabled, trains will be prevented from parking at this station if one of their cargo wagons would be filled with fuel.

### Station control mode

![Image](https://raw.githubusercontent.com/mamoniot/project-cybersyn/main/previews/science.png)

When placed adjacent to the train stop of an already existing Cybersyn station, this combinator will provide a second set of inputs and outputs that can be used to more precisely control this station. The combinator input allows for request thresholds to be set per-cargo. Any non-zero cargo signal given on the input circuit network will override the station's request thresholds for just that cargo. When this is used on a provider station, if the station has more cargo than the input threshold, it will force the creation of a delivery for that cargo to the next available requester station. This effectively overrides the requester station's request threshold. This is useful for purging unwanted cargo from provider stations.

If a station control combinator receives a "priority" signal as input, it will apply that priority to each cargo signal it is receiving as input. This allows you to specify up to 2 different priorities per-cargo on a single station.

The output of the combinator gives the sum total of all cargo loading or unloading orders in progress for the station. The very tick a train is dispatched for a new order to the station, that order is added to the output of this combinator, and it is removed as soon as the train leaves the station. The primary use case for this is to prevent duplicate orders from being generated for stations that provide the same pool of cargo. Only one train can be dispatched per-tick per-cargo specifically to accommodate this.

### Wagon control mode

![Image](https://raw.githubusercontent.com/mamoniot/project-cybersyn/main/previews/filtered-slots.png)

When placed adjacent to the tracks of an already existing Cybersyn station, this combinator will connect to any wagon that parks adjacent to it. The output of this combinator gives the list of cargo expected to be loaded or unloaded to just this specific wagon. In addition, if this wagon is a cargo wagon, its slots will automatically be filtered so items can only enter it in sorted order. These combined make it straightforward to precisely load a cargo wagon to the exact specification desired by the requesting station. Connect the output to a filter inserter, keep a count of how many items have been loaded into the wagon with a memory cell, and use an unloading inserter to remove any items that exceed the requested load amount. If done correctly you have built a universal item loader for this cargo wagon. Build one of these units for each cargo wagon along the station and you have created what I call a universal station. The input of a wagon control combinator has no function currently.

### Secondary inventory mode

When placed adjacent to the train stop of an already existing Cybersyn station, this combinator adds another inventory to that station. Connect its input to a circuit network the same way as a station combinator's: a positive cargo signal provides that cargo to the network, a negative cargo signal requests it. The central planner treats each secondary inventory as a stop of its own at that station, so its cargo is matched, prioritized and thresholded separately, while trains still drive to the one train stop. A station can have any number of secondary inventory combinators.

A secondary inventory combinator reads its own request threshold, fluid request threshold, priority and reserved fluid capacity signals, and uses the station's values for any of these it does not receive. It always belongs to the station's network; a signal of the same Id as that network sets its own network mask, and when the station's network is "each", each virtual signal it receives sets its mask for that network. Everything else belongs to the station: provide only or request only, stack thresholds, the per-cargo thresholds of a station control combinator, the train limit, the allow-list and the deliveries in progress. Deliveries in progress to or from the station count against every one of its inventories. The loading and unloading orders for a secondary inventory's deliveries appear on the station combinator's output and on the wagon control combinators, as for the station's own deliveries; the secondary inventory combinator outputs nothing.

For example, a smelting station can provide plates to the main network from its station combinator while a secondary inventory combinator on the same stop requests ore from a mining sub-network on a different mask bit, with its own request threshold of one wagon. One train stop and one train limit serve two entries in the economy.

The combinator displays an I, which turns red while one of its own requests could not be dispatched.

### Networks

![Image](https://raw.githubusercontent.com/mamoniot/project-cybersyn/main/previews/gui-network.png)

Stations, depots and refuelers can be set to belong to a particular network by setting that network on their combinator. By default all combinators belong to the "signal-A" network. By setting a different signal Id, the combinator will belong to that different network. Networks identified with different signal Ids do not share any trains or cargo; Orders will never be generated to transfer cargo between separate networks.

In addition, if the combinator receives as input a signal of the same Id as its network signal Id, then the value of this signal will be interpreted as a bitmask to give 32 "sub-networks" to choose from. Each station can belong to any set of sub-networks based on its mask. A delivery will only be made between two stations if any two bits match between the two masks, i.e. if `mask1 & mask2 > 0`. When a network Id is a type of cargo, that cargo will be ignored by stations, its signal will only ever be interpreted as the network mask.

A network can be set to the "each" virtual signal. When in this mode, each virtual signal given to them as input is interpretted as a network mask for that network Id. The stop is thus made a part of that network with the specified network mask. This allows you to union together as many different networks as you would like.

### Request threshold

![Image](https://raw.githubusercontent.com/mamoniot/project-cybersyn/main/previews/virtual-signals.png)

If a station combinator receives a request threshold signal as input, a request order for the station will only be generated if the station is requesting a number of cargo exceeding the request threshold. In addition, there must be a station in the network which is providing at least as much cargo as the request threshold, and there must be a train in the network that has cargo capacity exceeding the request threshold. Therefore all generated orders must be for a number of cargo greater than or equal to the request threshold. By setting high thresholds, the traffic on your network can be greatly reduced, at the cost of needing to maintain larger cargo buffers at each station. The request threshold signal sets the request threshold "per-station" whereas the station control combinator can set or override the threshold per-cargo as well.

On station combinators there is a setting called "Stack thresholds". When set, any request threshold for this station will be multiplied by the stack size of any item it is being compared to. This applies to station control thresholds as well. Thus the request threshold can be specified based on total stack count rather than total item count. Fluids are unaffected by the "Stack thresholds" setting, they are always specified by total fluid count.

There is no "provide threshold" in this mod because by design there is no need for one. Because the request threshold is enforced on the provider station as well as the requester, it pulls double duty as both the request and provide threshold.

### Locked slots per cargo wagon

After an order has been generated, enough cargo will be subtracted from that order to ensure at least X number of slots in each cargo wagon can be left empty, where X is the "Locked slots per cargo wagon" signal being received by the station combinator. It is necessary for multi-item stations to function.

When the map setting "Reserve locked slots per item type" is enabled, X slots are left empty in each cargo wagon for every item type in the order instead: with 2 locked slots and 3 item types, each cargo wagon keeps 6 slots empty, so every item has room for its surplus. Fluids do not count as item types. This setting is disabled by default, which gives the behavior described above.

### Priority

Orders will be generated first for stations, depots and refuelers which are receiving a higher priority signal than the others. If multiple depots or refuelers have the same priority, the closest one will be prioritized. Depots calculate distance based on the location of their train. If multiple stations have the same priority, the least recently used requester station will be prioritized, and the provider station closest to the requester station will be prioritized. So in times of cargo shortage (front-pressure), round robin distribution will be used, and in times of cargo surplus (back-pressure), minimum travel distance distribution will be used. Provider stations will be prevented from providing cargo to lower priority requester stations until the highest priority requester station is satisfied.

If a combinator set to station control mode receives a priority signal, for each cargo signal input to the combinator, cargo of that type will have its priority overridden in addition to its request threshold. This effectively allows you to choose one of two possible priorities for each cargo that a station processes.

### Train limits

Works based off of the train limit set on the train stop in the same way it does in vanilla Factorio. Only a number of trains up to the train limit will be allowed to dispatch to the station by the central planner. Useful to reduce the need for train stackers and to prevent deadlocks.

## Cybersyn Manager

Open the manager with **Ctrl+T** or the shortcut bar button "Toggle Cybersyn Manager". The window sizes itself to your screen and shows as many whole rows as fit. Its tabs are **Overview**, **Inventory**, **Stations**, **Trains** and **Log**, plus **Utilization** and **Breakdown** when the map setting "Enable analytics" is on and the [factorio-charts](https://mods.factorio.com/mod/factorio-charts) mod is installed.

### Overview

Four tiles and one table. **Unserved stations** counts stations with a request the central planner is not serving, broken down by reason for the requests that have waited longer than five minutes. **Fleet headroom** is the fewest trains available on any network over the chosen period, with "Free trains now" and the no-train failures below it. **Stations failing** splits into no power, disabled, throttling (a train limit is holding a request back) and misconfigured. **Throughput** covers deliveries, average trip and dispatch wait for the period: Last 10 min, Last hour or Last 24 h.

Clicking a tile opens the list behind its number. The **Unserved requests** table below lists each waiting request with its reason, the best provider, its stock against what is needed, the requester it lost to and how long it has waited. While "Enable central planning" is off, a Dispatch paused banner shows on every tab and panel.

![Image](https://raw.githubusercontent.com/mamoniot/project-cybersyn/main/previews/manager/explain.png)

Click a request's reason and an **Explain** frame opens beside the window with what the central planner recorded, the fix, the recent reason changes and any setup finding that blocks the request. The tick button at the end of a row acknowledges it: click for 24 h, shift+click for 1 h, ctrl+click until the reason changes. Acknowledged requests stop counting and leave the table; tick "Show acknowledged" to see them greyed out.

### Stations and setup checks

![Image](https://raw.githubusercontent.com/mamoniot/project-cybersyn/main/previews/manager/stations.png)

One row per combinator that carries an inventory: a station's station combinator first, then each of its secondary inventory combinators in the order they were built, each with its own network and mask, priority and provided and requested items. A secondary inventory's row ends in a small grey combinator icon that names it and opens it. The other columns show the status, deliveries against the train limit, the oldest request's wait and the time since a train was last dispatched to or from it, and every column sorts from its header. The chips along the top filter by status (No power, Disabled, Warming up, Starved, Setup, Saturated, Idle, OK) and add **Unserved**, **With stuck train**, **Failing** and **Problems**. The footer counts stations and, when some station has secondary inventories, rows.

![Image](https://raw.githubusercontent.com/mamoniot/project-cybersyn/main/previews/manager/stations-problems.png)

While a manager window is open, setup checks walk every station and train in small batches and flag configurations that keep a request from ever being served: a threshold no train can carry, an allow-list no train fits, a stop with no network bit, the same item provided and requested, phantom deliveries, a train group spanning depot names, a schedule naming a missing stop, trains never refueled, and more. Turn on the **Problems** chip to list them worst first, each with its fix. A stop or combinator that does not make a working station at all (on the wrong side, a ghost, doubled) is listed after the stations. A station that would otherwise be OK but has an open setup error shows the status **Setup**. `/cybersyn-find-problems` prints the stops and combinators that do not make a working station, and the Cybersyn stops with a non-default train stop priority, to chat.

### Trains

![Image](https://raw.githubusercontent.com/mamoniot/project-cybersyn/main/previews/manager/trains-pane.png)

Rows show the train ID, what it is doing and where, network, composition, depot, state, time in that state, last refuel, fuel and shipment. Columns that every listed train shares are hidden and named in the header tooltip. Chips filter by train state, plus **In interrupt**, **Not refueled > 1 h**, **In vanilla group**, **In trouble** and **Problems**. "Group by depot" folds the list into one row per depot name.

Click a row to open the detail pane: a camera following the train, its shipment, provider and requester, its schedule with the active record marked, and its last log events. The vanilla trains window gets an "Open Cybersyn Manager" button.

### Inventory and item drill-down

![Image](https://raw.githubusercontent.com/mamoniot/project-cybersyn/main/previews/manager/item-drilldown.png)

Three grids, **Provided**, **In transit** and **Requested**, in the crafting menu's order by default and sortable by amount, stations, wait or deficit. They update in place, and the layout holds still while the pointer is over a grid. "Dim unrequested" greys out the items nobody on the same network requests.

Click an item anywhere in the manager or its panels to set the item filter and see everyone who touches it on the Inventory tab: **Providers** with stock and outgoing deliveries, **Requesters · dispatcher order (approximate)** with priority, threshold, wait and why each one is not being served, and **Trains carrying it**. Each list scrolls on its own. **Back**, or the × on the item filter, clears the filter and brings the grids back. Shift+click an item to list the stations that have it instead; right-click clears the item filter.

### Log and diagnostics

![Image](https://raw.githubusercontent.com/mamoniot/project-cybersyn/main/previews/manager/log.png)

The **Log** tab reads the diagnostics log, newest first. It follows new events until the pointer rests on the list or you press **Pause**; **Newest** jumps back. Filter by severity, by kind (Unserved requests, Deliveries, Stations, Trains, Cargo, Setup, Actions), by train ID and by time window (Last 10 min, Last hour, Everything kept). Hovering a row's message explains the cause and what to do about it. **Summary** swaps the rows for the stations and items with the most events. The print button on a row posts it to chat with clickable train, stop and map tags, and the export button writes the filtered rows to `script-output/cybersyn/diag-<tick>.csv`. The tab badge counts errors since you last looked.

How much is recorded is set by the map setting "Diagnostics". **Basic**, the default, keeps why each unserved request is waiting plus failures, alerts and station changes in a 4,096-row log. **Full** also logs every dispatch, arrival, departure and train state change in a second, 16,384-row log, which holds about 15 minutes on a large base. **Off** records nothing and hides the Log tab.

### Utilization and Breakdown

With "Enable analytics" on and factorio-charts installed, **Utilization** charts the share of each train layout that is out on a delivery, with one line per layout, range buttons from 1m to 1000h, a time axis and a crosshair tooltip. The Train types legend gives each layout a checkbox to show or hide its line and its average over the range. **Breakdown** shows the time every delivery spends in each phase and names stuck reasons the same way as the Unserved requests table.

### Stop and train panels

![Image](https://raw.githubusercontent.com/mamoniot/project-cybersyn/main/previews/manager/stop-panel.png)

Open a train stop and a **Cybersyn** panel docks to the right of the vanilla window. It shows the stop's role, network and mask, status, deliveries against the train limit, a Networks line with every network the station advertises on, and an **Advertised** block per combinator, headed by its letter in the color of its display (S for the station combinator, I for a secondary inventory), its name and priority, and its network and mask. Below come the unserved requests with their reasons and fixes, deliveries in flight, setup findings and the stop's last log events. **Effective config** expands into the numbers the central planner really uses: the threshold and where it came from, the stacks it fills, the largest eligible train and the allow-list. When no manager window is open, the panel reads the stop live.

The panel's item slots open the item's drill-down for that station, and its deliveries in flight open the Trains tab filtered by the item and the station; shift+click opens the same view for every station. **Open in manager** opens the manager on that station: a station chip beside the item filter keeps only its rows on the Stations and Inventory tabs, the trains delivering to or from it and the Log events naming it, until you click the chip to remove it. **Recount deliveries** repairs a delivery counter that a failed delivery left too high.

![Image](https://raw.githubusercontent.com/mamoniot/project-cybersyn/main/previews/manager/train-panel.png)

A locomotive gets the same treatment: a panel beside the vanilla train window that shows what the train is doing, its shipment, depot, schedule and last events, with **Send home**, a path trace that draws the rest of the train's route for 10 s, a map pin and **Open in manager**.

### Links, search and filters

Station, train and item names in every table are buttons. Click to open, Shift to show on the map, Ctrl for the station's combinator, Alt for its station control combinator, Ctrl+Shift to drop a map pin. Show on map closes the manager window; **Locate** in the Trains pane, and beside a train waiting at a signal, shows it on the map and keeps the window, with a **Back** button.

The title bar holds search (Ctrl+F; space-separated words, case-insensitive), the filter row (item, network, network ID and surface; closing the row clears them), **Pause** and the pin. A pinned window stays open while you interact with the world. Ctrl+F does not reach a pinned window: the key goes to the GUI in front of it, or to the map search; click the search button instead. E and Escape close the top layer first (search, Explain, the train pane) and then the window, as in the game's own windows; a pinned window ignores them. `/cybersyn-reset-gui` centers the window, sizes it for your screen again and closes the filter row.

### Unserved line on screen

Turn on "Manager: Unserved line on screen" in your per-player settings for a small draggable box with the number of unserved requests, the free trains now and the most common reason, refreshed every 5 seconds. Clicking it opens the manager.

### Actions and commands

Actions that change the game state sit where they apply: **Send home** on the train panel and the Trains pane, **Recount deliveries** on the stop panel. They and the console commands `/cybersyn-fix-priorities`, `/cybersyn-abolish-same-depot`, `/cybersyn-recalculate-train-size` and `/cybersyn-refresh-allow-lists` are allowed for the players chosen by the map setting "Manager actions allowed for": Admins by default, Everyone or Nobody. Single player is always allowed. Every action is printed to the force and written to the log.

`/cybersyn-refresh-allow-lists` re-reads the layout of every train, up to 50 trains every 10 ticks (fewer on large bases, where a train with a unique layout is checked against every station), so every station's allow-list knows them. `/cybersyn-find-problems` and `/cybersyn-reset-gui` change no game state, and are open to everyone.

Other mods can read the same data through the read-only remote interface `cybersyn-query` (`query_unserved`, `query_counts`, `query_station`, `query_train`), which returns plain tables for HUDs and overlays. Each `query_unserved` call without a `requester` walks the whole diagnostics table, so poll it on a timer of a second or more, not every tick.

## Mod settings

Besides the central planning settings and defaults, the map settings include:

* **Diagnostics**: Off, Basic (default) or Full. See [Log and diagnostics](#log-and-diagnostics).
* **Manager actions allowed for**: Admins (default), Everyone or Nobody. See [Actions and commands](#actions-and-commands).
* **Alert for unexpected cargo pickup**: alerts when a train leaves a provider carrying an item type its order did not name. Disabled by default.
* **Reserve locked slots per item type**: see [Locked slots per cargo wagon](#locked-slots-per-cargo-wagon). Disabled by default.
* **Enable analytics**: turns on the Utilization and Breakdown tabs, which need factorio-charts. Disabled by default.
* **Manager updates per second**: how often an open manager window refreshes. 1 by default.

Per player:

* **Manager: Unserved line on screen**: see [Unserved line on screen](#unserved-line-on-screen). Disabled by default.

## Performance

The manager and the diagnostics are built so that a megabase pays almost nothing for them.

* **Nothing is collected or rendered while no manager window is open.** What remains is bounded: constant-time bookkeeping per dispatch, delivery and schedule change (the throughput buckets, alert merging, the interrupt flag), the setup-check registry kept current on build, remove and rename events, the diagnostics state unless the map setting "Diagnostics" is Off (Basic by default), the Utilization sampling when analytics is on, the opt-in Unserved line, and cheap per-tick and per-5-s checks that return at once.
* **The manager reads incrementally.** It reads a slice of stations per manager update into a snapshot, only while at least one player has the window open and unpaused, and keeps that snapshot for 2 minutes after the last window closes so a quick reopen is instant.
* **Each tab's work per update is sized** to stay within about 3 ms for the Overview, 1 ms for the Log and 5 ms for the others on a 2,000-station base. Rows are reused and only changed cells are rewritten.
* **The diagnostics log is two fixed-size rings** (4,096 rows in Basic, plus 16,384 in Full), so neither UPS nor the save grows with play time.

Measured on a Pyanodons save with 2,082 stations, 522 depots and 553 trains, Factorio 2.1.23 headless:

| What | Result |
|---|---|
| Whole game tick with the manager closed and Diagnostics Basic (default), against Project Cybersyn 2.1.2 (`--benchmark`, 1,800 ticks, 3 interleaved runs each) | 5.51 ms vs 5.50 ms (-0.01 ms) |
| Manager tick with every window closed | 0.0002 ms per game tick at 1 update/s |
| Diagnostics recording hooks, Basic (default) / Full | 0.0067 / 0.0087 ms per game tick |

## Development

Host unit tests run without Factorio, under plain Lua 5.2 (`lua5.2` on the path):

```
tests/unit/run.sh
```

It runs from any directory, prints one line per failure and a final `PASS n FAIL m` (555 tests in under a second), and exits non-zero on any failure. Set `CYBERSYN_ROOT` to test a mod directory other than `cybersyn/`.

`tests/unit/harness.lua` stands in for just enough of the runtime (`storage`, `prototypes`, `game`, flib's gui and format) to load the pure modules. The tests cover the manager's view models and text (`scripts/gui/*-model.lua`, `*-text.lua`, `tab-logic.lua` and the like), the diagnostics and statistics bookkeeping, the setup checks, the planner's matching through `planner_fixtures.lua`, and the 2.2.0 save migration. Anything that needs the real engine (entities, the circuit network, train pathing, rendering, GUI layout) stays out of them and needs a test in game.
