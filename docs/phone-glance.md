# Phone glance

The compact, read-only fleet summary the authenticated Discord phone channel returns on request.
[`bin/fm-phone-fleet-summary.sh`](../bin/fm-phone-fleet-summary.sh)'s header owns the complete omission order, exact length budget, and the rest of the redaction rules.

A short board or fleet-status request in the phone channel returns five ordered columns as one compact message.
The glance reads the canonical fleet snapshot directly and includes no effort maps, decision controls, or other review interaction from the interactive `/bearings lavish` board.
Each entry carries only the work title and, when there is one, its full pull request URL; the worker runtime, model, and effort the board shows stay off the phone.
It targets one phone screen; when the fleet is too large, it drops Landed entries first, reports omitted counts by column, and invites a narrower column follow-up.
The glance is generated only on request and is never scheduled, pushed on change, pinned, or edited in place.
That is what separates it from the one live pinned-style summary [`bin/fm-phone-summary.sh`](../bin/fm-phone-summary.sh) keeps current by editing the same message in place.
