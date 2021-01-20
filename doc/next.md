Next
====
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

- handle_response needs work, deal with many responses.
- handle_request same
- deal with freakin return values of nng.
- serialization needs work,
	- struct serialisation / deserialisation.
	- package definition should be shared and reused.
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

