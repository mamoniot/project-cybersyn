# Project Cybersyn

Behold one of the most feature-rich and performant logistics mods Factorio has to offer. Named for [Project Cybersyn](https://en.wikipedia.org//wiki/Project_Cybersyn) of Allende's Chile, with just this mod you can coordinate the economic inputs and outputs of your entire megabase.

## Features

### A whole suite of new and optional circuit network inputs and outputs to control your stations precisely
* Natively read out all deliveries currently in progress for a station, not just the loading or unloading orders of the parked train.
* Set request thresholds per item instead of just for the entire station.
* Read out item loading or unloading orders per train wagon, instead of just for the entire train.
* Set item filters per cargo wagon, making multi-item deliveries far less of a headache.

These all combine to make it possible to **create "universal" stations**; stations that provide any arbitrary number of different items for a train of any arbitrary length! Build stations that supply you all items from your mall, stations that grab selected items from your disorganized storage chests, or stations that transfer any item between two otherwise completely distinct networks! The possibilities are far less limited.

**Intuitive and easy to learn**, without sacrificing features. Configure your stations using just 3 virtual signals, a couple of combinator settings and the train stop's own train limit.

**Improved fault handling.** Mistakes and misconfigured stations are unlikely to result in items being delivered to places they shouldn't, and the player will be alerted immediately about the fault.

Stations can **automatically build allow-lists for trains** they can load or unload. Inserters or pumps adjacent to the station's tracks are auto-detected. No more deadlocks caused by trains mistakenly attempting to fulfill a delivery to a station that cannot unload it. This feature is compatible with miniloaders.

**Easy and versatile ways to define separate train networks.** Bitwise network masks are now optional! The total number of possible train networks is 32 times the total number of circuit signals in the game.

Runs a custom, **highly optimized central planning algorithm**, resulting in exceptionally good performance. Outperforms LTN in testing *(disclaimer: there is no perfectly apples-to-apples performance test since the features and algorithms of these mods are not the same)*. The station update rate is twice that of LTN by default, and depots don't count towards station updates.

**Native space exploration compatibility!** Without any trouble this mod will automatically detect any space elevator on the planet and add it to the orders of trains which want to travel between surfaces. Unless there is a space elevator connecting the surfaces, each surface must be set to its own network.

Built from the ground up to be **free and open source forever**. *¡Viva la Revolución!*

Custom art and models to come in future updates!

## Mod Details

This mod adds a single new entity to the game, the cybernetic combinator. This combinator can be in one of 4 different possible control modes. While each mode has a purpose, the only modes you have to use are primary station control and depot control.

### Primary station control combinator

When placed adjacent to a vanilla train stop, a Cybersyn station is created. This station can provide or request items to your train network. Connect the input of the combinator to a circuit network; When a positive item signal is received, this station will provide that item to the network, when a negative signal is received, this station will request that item from the network. When a station is providing an item that another station is requesting, a train order will automatically be generated to transfer those items from the providing station to the requesting station. When a train arrives to fulfill this order, the output of the combinator will give the full list of items expected to be loaded (positive) or unloaded (negative) from the train.

### Depot control combinator

When placed adjacent to a vanilla train stop, a Cybersyn depot is created. Any train which parks at this depot will automatically be added to the train network. Whenever a train order is generated, if this train has the cargo capacity to fulfill it, and is allow-listed by both stations, then it will automatically be dispatched to fulfill the order. When the order is completed, the train will return to any train stop with the same name as the depot it first parked in. This almost always means it returns to a Cybersyn depot where it will again await to fulfill a new order. To save on UPS the input of a depot control combinator is only read when a train parks at the depot; this only matters for networks which make extensive use of network masks on depots.

### Optional station control combinator

When placed adjacent to the train stop of an already existing Cybersyn station, this combinator will provide a second set of inputs and outputs that can be used to more precisely control this station. The combinator input allows for request thresholds to be set per-item. Any non-zero item signal given on the input circuit network will override the station's request thresholds for just that item. The output of the combinator gives the sum total of all item loading or unloading orders in progress for the station. The very tick a train is dispatched for a new order to the station, that order is added to the output of this combinator, and it is removed as soon as the train leaves the station. The primary use case for this is to prevent duplicate orders from being generated for stations that provide the same pool of items. Only one train can be dispatched per-tick specifically to accommodate this.

### Wagon control combinator

When placed adjacent to the tracks of an already existing Cybersyn station, this combinator will connect to any wagon that parks adjacent to it. The output of this combinator gives the list of items expected to be loaded or unloaded to just this specific wagon. In addition, if this wagon is a cargo wagon, its slots will automatically be filtered so items can only enter it in sorted order. These combined make it straightforward to precisely load a cargo wagon to the exact specification desired by the requesting station. Connect the output to a filter inserter, keep a count of how many items have been loaded into the wagon with a memory cell, and use an unloading inserter to remove any items that exceed the requested load amount. If done correctly you have built a universal item loader for this cargo wagon. Build one of these units for each cargo wagon along the station and you have created what I call a universal station. The input of a wagon control combinator has no function currently.

### Networks

Stations and depots can be set to belong to a particular network by setting that network on the control combinator. By default all combinators belong to the "signal-A" network, by setting a different signal Id, the combinator will belong to that different network. Networks identified with different signal Ids do not share any trains or items; Orders will never be generated to transfer items between separate networks. In addition, if the combinator receives as input a signal of the same Id as its network signal Id, then the value of this signal will be interpreted as a bitmask to give 32 "sub-networks" to choose from. Each station can belong to any set of sub-networks based on its mask signal. A delivery will only be made between two stations if they have matching masks, aka if `mask1 & mask2 > 0`. When a network id is an item, that item will be ignored by stations, its signal will only ever be interpreted as the network mask.

### Request threshold

If a primary station control combinator receives a request threshold signal as input, a request order for the station will only be generated if the station is requesting a number of items exceeding the request threshold. In addition, there must be a station in the network which is providing at least as many items as the request threshold, and there must be a train in the network that has cargo capacity exceeding the request threshold. Through this logic all generated orders must be for a number of items greater than or equal to the request threshold. By setting high thresholds, the traffic on your network can be greatly reduced, at the cost of needing to maintain larger item buffers at each station. There is no "provide threshold" in this mod because by design there is almost no need for one. If desired a provide threshold can be simulated with a single decider combinator. The request threshold signal sets the request threshold "per-station" whereas as mentioned before an optional station control combinator can set the threshold per-item instead.

### Locked slots per cargo wagon

After an order has been generated, enough items will be subtracted from that order to ensure at least X number of slots in each cargo wagon can be left empty, where X is the "Locked slots per cargo wagon" signal being received by the station control combinator. It is necessary for multi-item stations to function.

### Priority

Orders will be generated first for stations and depots which are receiving a higher priority signal than the others. If stations have the same priority, the least recently used request station will be prioritized, and the provide station closest to the request station will be prioritized. So in times of item shortage (front-pressure), round robin distribution will be used, and in times of item surplus (back-pressure), minimum travel distance distribution will be used.

### Train limits

Works based off of the train limit set on the train stop in the same way it does in vanilla Factorio. Only a number of trains up to the train limit will be allowed to dispatch to the station by the central planner. Useful to reduce the need for train stackers and prevent deadlocks.
