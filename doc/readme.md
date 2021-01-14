ZIG NNG
=======
NNG based DHT

- Simple single event loop
  - This seems to be the easiest, we make progress now.
  - need to seperate code, dealing with different protocol issues.
  - Maybe can now find a way to abstract things.

Serialization
=============
Serialization is becoming a pain, maybe ptrcasts, order of serialization gets mixed up.
Probably needs general serialization ala whats in std.zig



Socket
======
For reading:
- nng_rep0_open
- nng_listen

For writing:
- nng_req0_open
- nng_dail

Incoming Messages
=================
receiving with simple state machine, with aio callback (void ptr to worker).
A fixed number of workers is active on the socket.

- nng_alloc(Work)
- nng_aio_alloc(work.aio, callback, work)
- nng_ctx_open(work.ctx, sock)

Init -> Recv
- nng_ctx_recv
Recv -> Wait
- nng_aio_result -> Fail
- nng_aio_get_msg -> work.msg
- (nng_msg_trim_u32) -> Fail

// Here callback into something else should happen
Wait -> Send
- nng_aio_set_msg <- work.msg //During wait, msg should have been set
- nng_ctx_send
Send -> Recv
- nng_aio_result -> Fail
- nng_ctx_recv
Fail -> Recv:
- nng_msg_free
- nng_ctx_recv

Outgoing Messages
=================
Several outgoing sockets are needed.
A queue of workers might be required.
A queue of tasks can be in the pipeline.
A thread is reading the queue and setting up workers, and reusing them when needed.



Worker should have a Ready state.
