[Design Document]
Describes the general design elements
- central job queue to make things simple
- guids are the central identifier to manage how to deal with work
- Reply and Request struct with guid and data.
	- union(enum) to serialize.

[Xor]

      /\
    /\  /\
    x y z n
    x -> y z n
    y -> x n z
- Central distance unit.
- Store nearest to ID's created from own ID
- Store everything nearer than nearest connected ID in routing table.
- Nearest ID (and n id's above that), gives idea of network size.
	- Three of nearest ID, next ID above, ..etc.

[Data]
- Current block size: 64kb
	- seems small enough but still substantial
	- Can store a small image (1200x800 webp 80%)

- Two types of data
	[Regular Hash Item]
	  - Stores value, Key is hash of Item
 	  - Central storage unit
	[Publish Value Item]
      - Hash public key -> ID
      - Makes sure you can't just store any hash
      - Store operation has: 
		- ID
   		- public key + signature
   		- Value to store
   		- Increment number
   	  - Allows to have central place to store and publish

These two items can do a lot!
Together with general Get on Conn ID, you can have safe general updating and publishing.

- Connection Item
 - ID -> sockaddr
 - ID is right now disconnected from its connection data
 - Probably best to keep it disconnected, we can always still store them.
 - Kademlia stores these in the DB.
   - hashes conn data and uses that as ID (don't like it)
   
[Redundancy]
- Redundancy is a real issue.
- Current schemes store data only in one place!
- Obviously you should store your own data
	- Could either be separate DB
	- Or you flag your data in a hashmap / bloom filter so you don't delete it / know what to backup
- Other schemes, You don't only store data just right before yourself, but also before ID's in your routing table?
  - How would this factor in in the routing?
    - I guess if you happen to have it, just reply immediately.
    - Also, you can check these items with the node in your table; they should be storing them!

[Network discovery]
- Initial IP from program input (or db)
- Incoming pings are stored as 'possibles'
- Own IPs should be stored in hashmap to filter (obtained from pings)


[Routing Table]
  Request Next: [IDx]
  - [ID ^ b31]  [ID ^ b30] [ID ^ b29] .. [ID ^ b0]
    - the .. part might omit, but we need the last one (next)
  [ID0]         [ID1]       [ID2]       [ID3]

  - If IDx nearer than ID0, return self
  - Otherwise pass on to nearest ID
  - This should allow network discovery

  - 

  Structure:
- [ID] -> (ID, constring)
- input id is the minimum distance points according to xor
- output is the actual ID and it's connection point (could also be nng_sockaddr)

- Keep routing table fresh with periodic checks


[Connection Maintenance]
What to do to keep connections up to date?
- Is there any connection? If not add N from 'knowns'
- Verify all connections are unconnected (otherwise remove them)
- Verify connections match routing table (get's updated in its own callback)

[On boarding]
How do you join the network / let another join
- Nodes have to interject themselves
- Do we just send all data?
  - Seem to be what others do
  - How do you make sure nothing goes wrong there?

Process from connector
- You need to find the one before you. This is your lower limit, you store after that.
	- He should put you in his routing table.
	- You can test-send a message to yourself.

- You need to find the one after you.
	- Also you will lower their limit
	- They should send data to you.
	- Initial issue, He won't reach you except for a longer path that might not be up to date?
	- 
	- Other can have a trail period in which it stores but also sends forward.

[Central Job queue]
- Jobs get processed in a queue (currently no priority implements, but some fair scheduling might be appropriate)
- union(enum)

[Connection]
- Has a unique guid to address in jobs

[InWorker]
- Has a guid pointing to *current* work id.

[OutWorker]
- Has a guid pointing to *current* work id.
- N workers per connection.

[Jobs]:
    - handle_request
    - handle_response
    - send_request 
    - send_response
    - store
    - get
    - connect
    - handle_stdin_line
    - bootstrap
    - connection_maintenance

[Threads]:
	- Timer (cron) scheduler
	- console

[Request-Response]:
	- find_nearest_next_conn ID (not including ID itself) -> ID, sockaddr
	- find_before_n ID -> N ID's before ID
	- get_data ID -> value
	- store_data ID Value -> ok
	- get_msg ID -> value
	- send_msg ID value ? Not sure
	- publish_data ID pub nonce value | sig -> segregate witness
