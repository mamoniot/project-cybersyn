# Project Cybersyn

Behold one of the most feature-rich and performant train logistics network mods Factorio has to offer. Named for [Project Cybersyn](https://en.wikipedia.org//wiki/Project_Cybersyn) of Allende's Chile, with just this mod you can coordinate the economic inputs and outputs of your entire megabase. Similar in functionality to the famous Logistics Train Network mod, but with a much broader scope.

![Image](https://raw.githubusercontent.com/mamoniot/project-cybersyn/main/previews/outpost-resupply-station.png)

## Quick Start Guide

Within Project Cybersyn, you can think of requester stations as requester chests, provider stations as passive provider chests, depots as roboports and trains as the logistics bots. There is a direct correspondence between the Cybersyn train network and Factorio's robot logistics network.

A bare minimum Cybersyn train network consists of 2 components: depots and stations. Both are created by placing a cybernetic combinator adjacent to a train stop. Select the "Mode" of the combinator to "Station" to create a station, and to "Depot" to create a depot. Create a basic train and order it to park at the depot you just created, it is now controlled by the Cybersyn network. Depots and stations can have any train stop name, names do not impact their function. The circuit network input of a station's cybernetic combinator determines what items that station will request or provide to the Cybersyn network. A positive item signal is interpreted as that station providing that item to the network; A negative item signal is interpreted as that station requesting that item from the network.

![Image](https://raw.githubusercontent.com/mamoniot/project-cybersyn/main/previews/basic-provider.png)
![Image](https://raw.githubusercontent.com/mamoniot/project-cybersyn/main/previews/basic-requester.png)

To make a basic provider station, create an item buffer of chests or tanks adjacent to the station's tracks, and connect that buffer by wire to the input of the cybernetic combinator. To make a basic requester station, repeat the same, except reverse the direction of the inserters or pumps so they are *unloading* instead of loading; then connect a constant combinator to the same circuit network, set it to output the number of item you want this requester station to keep loaded in its item buffer, and flip the sign of each so the signal strength is negative. Once the provider station contains the item being requested, a train will automatically be sent to deliver that item from the provider station to the requester station. The requester station's buffer will automatically be topped up on the item being requested. Be sure that the requester station has the space to at minimum unload 2 fully loaded trains.

Follow the above directions and you have set up a bare minimum Cybersyn network! You may continue adding onto it with more stations and depots and Cybersyn will automatically manage all of them for you. At some point you may notice small hiccups within this network, like trains attempting to deliver a tiny amount of an item instead of a full cargo load, or you may want to extend your network with things like multi-item stations or centralized train refueling. In either case refer to **Mod Details** below for a in depth explanation of every feature within this mod.

## Features

![Image](https://raw.githubusercontent.com/mamoniot/project-cybersyn/main/previews/gui-modes.png)

**Intuitive and easy to learn**, without sacrificing features. Eases the player into building a train logistics network using parallels between the robot logistics network. Configure your stations using just 3 virtual signals, a couple of combinator settings and the train stop's own train limit.

### A whole suite of new and optional circuit network inputs and outputs to control your stations precisely
* Natively read out all deliveries currently in progress for a station, not just the loading or unloading orders of the parked train.
* Set request thresholds per item instead of just for the entire station.
* Read out item loading or unloading orders per train wagon, instead of just for the entire train.
* Set item filters per cargo wagon, making multi-item deliveries far less of a headache.

![Image](https://raw.githubusercontent.com/mamoniot/project-cybersyn/main/previews/universal-station.png)

These all combine to make it possible to **create "universal" stations**; stations that provide any arbitrary number of different items for a train of any arbitrary length! Build stations that supply you all items from your mall, stations that grab selected items from your disorganized storage chests, or stations that transfer any item between two otherwise completely distinct networks! The possibilities are far less limited.

![Image](https://raw.githubusercontent.com/mamoniot/project-cybersyn/main/previews/gui-allow-list.png)

Stations can **automatically build allow-lists for trains** they can load or unload. Inserters or pumps adjacent to the station's tracks are auto-detected. No more deadlocks caused by trains mistakenly attempting to fulfill a delivery to a station that cannot unload it. This feature is compatible with miniloaders.

Trains can automatically visit **centralized fuel loaders**. It is not required that every single depot loads trains with fuel.

Trains can **bypass visiting the depot** if they have enough fuel. Trains spend far more time productively making deliveries rather than travelling to and from their depot. Fewer reserve trains are needed as a result.

**Easy and versatile ways to define separate train networks.** Bitwise network masks are now optional! Networks are identified by signal id first, then by signal strength.

![Image](https://raw.githubusercontent.com/mamoniot/project-cybersyn/main/previews/fault-alert.png)

**Improved fault handling.** Mistakes and misconfigured stations are unlikely to result in items being delivered to places they shouldn't, and the player will be alerted immediately about the fault.

Runs a custom, **highly optimized central planning algorithm**, resulting in exceptionally good performance. Outperforms LTN by a factor of ~3x *(disclaimer: there is no perfectly apples-to-apples performance test since the features and algorithms of these mods are not the same, see [project-cybersyn/previews/performance/](https://github.com/mamoniot/project-cybersyn/tree/main/previews/performance) for more details)*. The station update rate is twice that of LTN by default, and depots don't count towards station updates.

![Image](https://raw.githubusercontent.com/mamoniot/project-cybersyn/main/previews/se-compat.png)

**Native space exploration compatibility!** Without any trouble this mod will automatically detect any space elevator on the planet and add it to the orders of trains which want to travel between surfaces. Unless there is a space elevator connecting the surfaces, each surface must be set to its own network.

Built from the ground up to be **free and open source forever**. *¡Viva la Revolución!*

Custom art and models to come in future updates!

I'm accepting submissions for localizations/translations. If you can speak a non-English language, feel free to submit a pull request on my github for a new locale file. If you don't know how to do that, message me however you would like, such as a discussion thread on the mod portal, and I will walk you through how to create a translation for this mod.

If you like my work, consider supporting me on [ko-fi](https://ko-fi.com/lesbianmami).

## Mod Details

This mod adds a single new entity to the game, the cybernetic combinator. This combinator can be in one of 5 different possible modes. While each mode has a purpose, the only modes you are required to use are station mode and depot mode.

### Station mode

![Image](https://raw.githubusercontent.com/mamoniot/project-cybersyn/main/previews/multi-item.png)

When placed adjacent to a vanilla train stop, a Cybersyn station is created. This station can provide or request items to your train network. Connect the input of the combinator to a circuit network; When a positive item signal is received, this station will provide that item to the network, when a negative signal is received, this station will request that item from the network. When a station is providing an item that another station is requesting, a train order will automatically be generated to transfer those items from the providing station to the requesting station. When a train arrives to fulfill this order, the output of the combinator will give the full list of items expected to be loaded (positive) or unloaded (negative) from the train.

Stations can automatically build allow-lists. When this option is enabled, only trains that can be loaded or unloaded by this station will be allowed to make deliveries to it. Stations determine this based on what inserters or pumps are present at this station along its tracks. When disabled, all trains within the network are allowed.

Stations can be set to provide only or request only. By default stations can both provide and request, but when one of these options is chosen either requesting is disabled or providing is disabled.

### Depot mode

![Image](https://raw.githubusercontent.com/mamoniot/project-cybersyn/main/previews/big-depot.png)

When placed adjacent to a vanilla train stop, a Cybersyn depot is created. Any train which parks at this depot will automatically be added to the train network. Whenever a train order is generated, if this train has the cargo capacity to fulfill it, and is allow-listed by both stations, then it will automatically be dispatched to fulfill the order. When the order is completed, the train will return to any train stop with the same name as the depot it first parked in. This almost always means it returns to a Cybersyn depot where it will again await to fulfill a new order. To save on UPS the input of a depot combinator is only read when a train parks at the depot; this is only relevant for networks which make extensive use of network masks on depots.

### Fuel loader mode

When placed adjacent to a vanilla train stop, a Cybersyn fuel loader is created. Whenever a train completes a delivery, if it is running low on fuel (configurable in mod settings), it will attempt to visit a fuel loader before returning to the depot. The train will search for a fuel loader within its network that has not exceeded its train limit and that it is allow-listed for. If one is found it will schedule a detour to it to stock back up on fuel.

Fuel loaders can automatically build allow-lists. When this option is enabled, trains will be prevented from parking at this station if one of their cargo wagons would be filled with fuel.

### Station control mode

![Image](https://raw.githubusercontent.com/mamoniot/project-cybersyn/main/previews/science.png)

When placed adjacent to the train stop of an already existing Cybersyn station, this combinator will provide a second set of inputs and outputs that can be used to more precisely control this station. The combinator input allows for request thresholds to be set per-item. Any non-zero item signal given on the input circuit network will override the station's request thresholds for just that item. When this is used on a provider station, if the station has more items than the input threshold, it will force the creation of a delivery for that item to the next available requester station. This effectively overrides the requester station's request threshold. This is useful for purging unwanted items from provider stations.

If a station control combinator receives a "priority" signal as input, it will apply that priority to each item signal it is receiving as input. This allows you to specify up to 2 different priorities per-item on a single station.

The output of the combinator gives the sum total of all item loading or unloading orders in progress for the station. The very tick a train is dispatched for a new order to the station, that order is added to the output of this combinator, and it is removed as soon as the train leaves the station. The primary use case for this is to prevent duplicate orders from being generated for stations that provide the same pool of items. Only one train can be dispatched per-tick per-item specifically to accommodate this.

### Wagon control mode

![Image](https://raw.githubusercontent.com/mamoniot/project-cybersyn/main/previews/filtered-slots.png)

When placed adjacent to the tracks of an already existing Cybersyn station, this combinator will connect to any wagon that parks adjacent to it. The output of this combinator gives the list of items expected to be loaded or unloaded to just this specific wagon. In addition, if this wagon is a cargo wagon, its slots will automatically be filtered so items can only enter it in sorted order. These combined make it straightforward to precisely load a cargo wagon to the exact specification desired by the requesting station. Connect the output to a filter inserter, keep a count of how many items have been loaded into the wagon with a memory cell, and use an unloading inserter to remove any items that exceed the requested load amount. If done correctly you have built a universal item loader for this cargo wagon. Build one of these units for each cargo wagon along the station and you have created what I call a universal station. The input of a wagon control combinator has no function currently.

### Networks

![Image](https://raw.githubusercontent.com/mamoniot/project-cybersyn/main/previews/gui-network.png)

Stations, depots and fuel loaders can be set to belong to a particular network by setting that network on their combinator. By default all combinators belong to the "signal-A" network. By setting a different signal Id, the combinator will belong to that different network. Networks identified with different signal Ids do not share any trains or items; Orders will never be generated to transfer items between separate networks.

In addition, if the combinator receives as input a signal of the same Id as its network signal Id, then the value of this signal will be interpreted as a bitmask to give 32 "sub-networks" to choose from. Each station can belong to any set of sub-networks based on its mask. A delivery will only be made between two stations if any two bits match between the two masks, i.e. if `mask1 & mask2 > 0`. When a network Id is an item, that item will be ignored by stations, its signal will only ever be interpreted as the network mask.

Stations and fuel loader combinators allow their network to be set to the "each" virtual signal. When in this mode, each virtual signal given to them as input is interpretted as a network mask for that network Id. The station or fuel loader is thus made a part of that network with the specified network mask. This allows you to union together as many different networks as you would like.

### Request threshold

![Image](https://raw.githubusercontent.com/mamoniot/project-cybersyn/main/previews/virtual-signals.png)

If a station combinator receives a request threshold signal as input, a request order for the station will only be generated if the station is requesting a number of items exceeding the request threshold. In addition, there must be a station in the network which is providing at least as many items as the request threshold, and there must be a train in the network that has cargo capacity exceeding the request threshold. Through this logic all generated orders must be for a number of items greater than or equal to the request threshold. By setting high thresholds, the traffic on your network can be greatly reduced, at the cost of needing to maintain larger item buffers at each station. There is no "provide threshold" in this mod because by design there is almost no need for one. If desired a provide threshold can be simulated with a single decider combinator. The request threshold signal sets the request threshold "per-station" whereas the station control combinator can set or override the threshold per-item as well.

On station combinators their is a setting called "Stack thresholds". When set, any request threshold for this station will be multiplied by the stack size of any item it is being compared to. This applies to station control thresholds as well. Thus the request threshold can be specified based on total stack count rather than total item count. Fluids are unaffected by the "Stack thresholds" setting, they are always specified by total fluid count.

### Locked slots per cargo wagon

After an order has been generated, enough items will be subtracted from that order to ensure at least X number of slots in each cargo wagon can be left empty, where X is the "Locked slots per cargo wagon" signal being received by the station combinator. It is necessary for multi-item stations to function.

### Priority

Orders will be generated first for stations, depots and fuel loaders which are receiving a higher priority signal than the others. If stations have the same priority, the least recently used requester station will be prioritized, and the provider station closest to the requester station will be prioritized. So in times of item shortage (front-pressure), round robin distribution will be used, and in times of item surplus (back-pressure), minimum travel distance distribution will be used. Provider stations will be prevented from providing items to lower priority requester stations until the highest priority requester station is satisfied.

If a combinator set to station control mode receives a priority signal, for each item signal input to the combinator, items of that type will have its priority overridden in addition to its request threshold. This effectively allows you to choose one of two possible priorities for each item that a station processes.

### Train limits

Works based off of the train limit set on the train stop in the same way it does in vanilla Factorio. Only a number of trains up to the train limit will be allowed to dispatch to the station by the central planner. Useful to reduce the need for train stackers and to prevent deadlocks.
