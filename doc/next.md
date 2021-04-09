Recently:
========
- Seperate guid and hash map to make message filtering easier
  - guid is for broadcasting only atm
- 


Next
====
- network size estimate
  - nodes
  - items

- create 'ensure map', key, value pairs
  - a key can be without value, we need to request it
  - key can have dependents, they will be added to ensure (but noted by dependency)
    - procedure:
      - add key to ensure map
      - stuff will automatically be filled in
      - can either poll state, or register some Job

- introduce ring-slice bloom sync
  
- introduce ring redundancy with 2^n masking
  - each stores certain mask rings
  - request can use mask to query masked recepient
  - get procedure: try regular first, then masked increasingly
  
- introduce ring-slice
  - can be put in an updater that keeps it up to date
  - can give 'signals' when something is new
  - can 'easily' change range, multiple ring slices can be added
    - reuses what it already has, automatically gets rest

- currently somehow we keep adding connections to incoming nodes.
- implement finger table with:
  - regular syncing with adding connections
  - requesting of fingers
  - dealing with closing redundant / failing connections

- Probably Unify InWorker / OutWorker
  - both just send and receive, with waiting moments

[API and other messages]
- GetID, //get ID of connecting node
- GetMessage, //get general message. Arg is peer ID
- GetPrevPeer,
- GetNextPeer,
- GetPrevItem, //number can be supplied to get more than one
- GetNextItem, //number can be supplied to get more than one
- GetItem, //retrieve an item
- Store, // Store command -> check hash to be sure.

- Make work for 2 user scenario
	- for local tcp
	- perhaps also for others (inproc? natural multicore)
	- logic has to fit precisely. 
		- Each node needs 1 conn at least, if they are differnt.
		- better 2
	- log(2) -> 1, log(3) -> 2. 
		- ceil(log_2(2))
		
- Make work for 3 user scenario.
	- needs e
Later
=====
- mdns
- 


First goal:
==========
Simplest system

- One event queue
- Two worker types, incoming/outgoing
- incoming and outgoing messages have a processing ID
  - Currently created by originator (passed on to next node)
  - Each node might have to change it, to avoid collision
- Incoming message goes to process message task
- Sockets are 
- Outgoing workers have a context and socket index. (multiple context per socket).
  - To send message, find target ID closest to recipient, with a READY worker.
  - If no worker is ready, queue again (or fail, perhaps count failure)
- periodic tasks are added, like
  - Update routing table (updates the outgoing workers)

