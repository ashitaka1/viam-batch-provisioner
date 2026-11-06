# 48. Report, never delete, a machine found after an unknown create

Date: 2026-11-05

## Status

Accepted

## Context

When Viam's create call times out or drops the connection, `MachineBatch` can't tell whether the machine was made. It looks up the location for a machine under the name. Viam records no creator a client can compare, so a match may be the batch's own machine or one another operator or app instance created under the same name in the same seconds.

The batch used to delete any match, which cleans up its own half-made machine and destroys another operator's. Deleting only a match whose `created_on` falls after the create call began narrows the window but still deletes in the race it is meant to avoid, and depends on the Mac's clock agreeing with Viam's.

## Decision

The batch reports the match as possibly left in Viam, with its machine ID, and never deletes it. A lookup that finds nothing reports nothing left; a lookup that fails reports the machine as possibly left with no ID.

## Consequences

A timed-out create the batch did complete leaves a machine in Viam with no queued credentials, and its number is skipped by the next batch. The operator deletes it by hand, from the ID in the failure. Timeouts on create are rare.
