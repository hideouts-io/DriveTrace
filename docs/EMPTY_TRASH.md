# Empty Trash — proposal, not implemented

Reviewed against official Google documentation on 2026-09-29. No permanent-delete endpoint or control has been added or exercised. Existing Move to Trash remains recoverable until Google removes the item.

## API and consequences

Google supports `files.emptyTrash` (`DELETE /drive/v3/files/trash`). Without `driveId`, it permanently deletes the user's trashed files; supplying `driveId` targets that Shared Drive's separate trash. It is a scope-wide operation, not a request to delete only selected rows, search results, or locally cached items. It requires the full `https://www.googleapis.com/auth/drive` scope, already requested by the optional management connection. A metadata-only token cannot call it. [API reference](https://developers.google.com/workspace/drive/api/reference/rest/v3/files/emptyTrash).

Permanent deletion in Shared Drives requires Manager access; the API role is `organizer`. A broad OAuth grant does not override an item's permissions or organization policy. [Shared Drive access levels](https://support.google.com/a/users/answer/12380484?hl=en), [Drive roles](https://developers.google.com/workspace/drive/api/guides/ref-roles).

There is no normal Trash restore or app/API undo after permanent deletion. Google offers conditional recovery routes for some accounts; those are external recovery processes, not a guarantee or an app safeguard. Treat this action as irreversible. [Trash and deletion](https://developers.google.com/workspace/drive/api/guides/delete), [Google recovery guidance](https://support.google.com/drive/answer/1716222?hl=en).

## Proposed interface for review

1. Put **Review Empty Trash…** only on the Trash screen. Keep it out of the ordinary file context menu and give it no keyboard shortcut.
2. Require an explicit scope: **My Drive account trash** or **one named Shared Drive**. Show the current account identity and Drive ID; never offer an implicit all-drives action.
3. Re-read the account, grant, current permissions and live trash listing. Show counts, known bytes, unknown sizes, and coverage gaps. Disable execution if that review is incomplete. Clearly state that filtered rows and the local cache do not constrain the endpoint.
4. Explain that newly trashed items can arrive between review and execution: this endpoint has no reviewed-ID precondition. Recommend reviewing in Google Drive when that scope-wide race is unacceptable. A future “Delete these reviewed items permanently” feature would be a distinct design, not a silent substitute.
5. Require typing **EMPTY TRASH**, acknowledging permanent deletion, then pressing an explicit red **Permanently empty [scope] trash** button. Cancel is the default. Never run automatically or on a timer.
6. Do not blindly retry a destructive request after timeout: its result may be unknown, and a retry could affect newly trashed items. Reconcile the live state and ask for a fresh review. Do not claim cancellation can undo a submitted request.
7. Refresh metadata after a confirmed response, preserve historical observations, and distinguish API confirmation from observed Activity evidence. No fabricated actor records or deletion counts.

Implementation requires user review of this proposal. Testing would begin with synthetic transport responses; any real permanent-deletion test requires a separately identified disposable scope and explicit confirmation at action time.
