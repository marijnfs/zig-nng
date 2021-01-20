[Design Document]
Describes the general design elements
- central job queue to make things simple
- guids are the central identifier to pass manage how to deal with work
- Reply and Request struct with guid and data.
	- union(enum) to serialize

[DHT]
 - Current block size: 64kb
   - seems small enough but still substantial
   - Can store a small image (1200x800 webp 80%)

 - Two types of data
   - Regular Hash Item
 	 - Stores value, Key is hash of Item
     - Central storage unit
 - Publish Value Item
   - Hash public key -> ID
   - Store operation has: 
   	   - ID
	   - public key + signature
	   - Value to store
	   - Increment number

    - Connection Item
     - ID -> sockaddr
     - ID is right now disconnected from its connection data
     - Kademlia stores these in the DB.
       - hashes conn data and uses that as ID (don't like it)
   
   These three items can do a lot!


[Network discovery]
- Initial IP from program input (or db)
- Incoming pings are stored as 'possibles'
- Own IPs should be stored in hashmap to filter (obtained from pings)


[Routing Table]
  Request Next: [IDx]
  - [ID ^ b31]  [ID ^ b30] [ID ^ b29] .. [ID ^ b0]
    - the .. part might omit, but we need the last one (next)
  [ID0] [ID1]       [ID2]       [ID3]

  - If IDx == ID, return self of course (if known)
  - If IDx <= ID0 and > ID, return ID0
  - Otherwise pass on to nearest ID
  - This should allow network discovery

  

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
	- getNextConn
