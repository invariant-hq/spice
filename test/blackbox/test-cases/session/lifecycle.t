Session lifecycle commands are persisted metadata updates over the session
document.

Forking creates a child document with lineage and does not mutate the parent.

  $ spice session create --id parent --title Parent
  parent
  $ spice session fork parent --id child --title Child
  child
  $ spice session show child | sed -E 's/revision: sha256:[0-9a-f]+(:[0-9]+)?/revision: sha256:$HASH/; s/(created_at|updated_at): [0-9]+/\1: $TIME/'
  id: child
  title: Child
  preview: -
  lifecycle: active
  phase: idle
  events: 0
  forked_from: parent events=0
  cwd: $TESTCASE_ROOT
  created_at: $TIME
  updated_at: $TIME
  revision: sha256:$HASH
  $ spice session show parent | grep '^forked_from'
  forked_from: -

Archived sessions are hidden from ordinary list/search output and included only
when requested.

  $ spice session archive parent
  parent
  $ spice session list | grep '^parent' || echo hidden
  hidden
  $ spice session list --archived | grep '^parent'
  parent  idle   archived   just now  Parent
  $ spice session search Parent | grep '^parent' || echo hidden
  hidden
  $ spice session search --archived Parent | grep '^parent'
  parent  idle   archived   just now  Parent

Restoring an archived session makes it active and visible again.

  $ spice session restore parent
  parent
  $ spice session list | grep '^parent'
  parent  idle   just now  Parent

Deleting is a tombstone update. The document remains on disk, can still be
exported by id, and is hidden unless deleted sessions are explicitly included.

  $ spice session delete child
  spice: session delete requires --yes
  [2]
  $ spice session delete --yes child
  child
  $ test -f $SPICE_TEST_DATA_HOME/sessions/child/session.json && echo tombstone-saved
  tombstone-saved
  $ cat $SPICE_TEST_DATA_HOME/sessions/child/session.json | sed -E 's/"(created_at|updated_at)":[0-9]+/"\1":$TIME/g'
  {"version":1,"id":"child","metadata":{"title":"Child","status":"deleted","forked_from":{"parent":"parent","copied_events":0},"cwd":"$TESTCASE_ROOT","created_at":$TIME,"updated_at":$TIME},"events":[]}
  $ spice session list | grep '^child' || echo hidden
  hidden
  $ spice session list --deleted | grep '^child'
  child   idle   deleted    just now  Child
  $ spice session search Child | grep '^child' || echo hidden
  hidden
  $ spice session search --deleted Child | grep '^child'
  child  idle   deleted    just now  Child
  $ spice session export child | sed -E 's/"(created_at|updated_at)":[0-9]+/"\1":$TIME/g'
  {"version":1,"id":"child","metadata":{"title":"Child","status":"deleted","forked_from":{"parent":"parent","copied_events":0},"cwd":"$TESTCASE_ROOT","created_at":$TIME,"updated_at":$TIME},"events":[]}

Deleted sessions are terminal for lifecycle operations.

  $ spice session restore child
  spice: session is deleted: child
  [1]
  $ spice session archive child
  spice: session is deleted: child
  [1]
  $ spice session fork child --id grandchild
  spice: session is deleted: child
  [1]
