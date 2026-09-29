# Order Portal with QuickBooks Online Invoicing — Implementation Guide

**Environment:** Salesforce Developer Edition + QuickBooks Online (Intuit Developer sandbox, free Builder tier)
**Companion documents:** `02-QuickBooks-Online-Development-Guide.md` and `03-Salesforce-Developer-Edition-Org-Guide.md`
**Source requirement:** Order Portal with QuickBooks Online Invoicing – Business Requirement (Sep 21, 2026)

This guide is the master plan: architecture, data model, design decisions, build phases, and tests. The other two documents hold the system-specific setup detail. Where a detail depends on your org's licences or on real sandbox behaviour, it is marked **[VERIFY]**.

---

## 1. Goal and definition of done

Build a working proof of concept where:

1. A direct customer or a partner logs into an Experience Cloud portal, browses products, and places an order.
2. The order is saved in Salesforce (Order + OrderItem) and the user gets an instant confirmation.
3. Within moments, a matching invoice exists in QuickBooks Online, traceable to the Salesforce order, with no duplicates even on retry.
4. Payment changes in QuickBooks (paid, partial, overdue) show on the Salesforce Order without manual entry.
5. A user can request a full or partial return; an internal approver approves it; QuickBooks receives the correct credit memo/refund exactly once.
6. Every failure is visible, every order has an audit trail, and a partner can never see another party's data.

**Explicitly limited in this POC:** volume (Dev Edition storage/API limits), production QuickBooks keys, multi-currency, subscriptions, inventory handling of returned goods.

---

## 2. Architecture

```
 PORTAL (Experience Cloud, LWC)
   catalog -> cart -> submit
        |
        v
 Apex OrderSubmissionService (idempotent on Submission_Key__c)
   creates Order (Draft) + OrderItems, then Activated
        |
        v  publishes
 Platform Event: Order_Invoice_Request__e
        |
        v  trigger (batches IDs)
 Queueable (Database.AllowsCallouts) -- QboInvoiceJob
   1. ensure QBO Customer   2. build invoice   3. POST with requestid
   4. store QBO Invoice Id + status on Order   5. write QBO_Sync_Log__c
        |
        v
 QUICKBOOKS ONLINE  ---- webhook (Invoice/Payment/CreditMemo events) ---->
        ^                                                                  |
        |                                                        Salesforce Site
        |                                                   Apex REST (verify HMAC)
        |                                                                  |
        +---- GET invoice (fetch current state) <---- Queueable <---------+
                                     |
                                     v
                        update Order payment fields

 Nightly: Schedulable reconciliation batch  ->  flags drift, retries stuck syncs
 Returns: Return_Request__c -> Approval -> Return_Credit_Request__e -> Queueable -> QBO CreditMemo (+ apply/refund)
```

**Why this shape**
- **Platform Event + Queueable** keeps the customer's confirmation immediate and isolates the callout from the portal transaction.
- **Webhook + fetch** gives near-real-time payment status while spending few QuickBooks read calls.
- **Nightly reconciliation** catches missed webhooks and drift, which the requirement explicitly asks for.

---

## 3. Data model

### 3.1 Standard objects used

| Object | Role |
|---|---|
| Account | Three record types: **Partner**, **Direct Customer**, **Partner Customer** (end customer of a partner) |
| Contact | Portal users and business contacts |
| User | Portal login (created from a Contact) |
| Product2 / Pricebook2 / PricebookEntry | Catalog and pricing |
| Order | The authoritative sales record |
| OrderItem | Order lines |
| ReturnOrder / ReturnOrderLineItem | Only if available in your org **[VERIFY]**; otherwise use the custom return objects below |

### 3.2 Custom objects (3 required, 2 optional)

| Object | Purpose |
|---|---|
| `Return_Request__c` | Return header, status, approval, QBO credit memo/refund IDs |
| `Return_Request_Line__c` | Master-detail child: OrderItem, quantity, amount |
| `QBO_Sync_Log__c` | Every inbound/outbound integration event, error, and retry |
| `Partner_Customer__c` *(optional)* | Junction, only if one customer can have multiple partners |
| `QBO_Payment__c` *(optional)* | Only if you need per-payment history |

Also: 2 Platform Events (`Order_Invoice_Request__e`, `Return_Credit_Request__e`) and 1 Custom Metadata Type (`QBO_Config__mdt`).

### 3.3 Key custom fields on standard objects

| Object | Fields |
|---|---|
| Account | `QBO_Customer_Id__c` (External ID, unique), `Partner_Account__c` (lookup to Account, for Partner Customer type) |
| Product2 | `QBO_Item_Id__c` (External ID), `QBO_Tax_Code__c` |
| Order | `Placed_By_Account__c`, `Placed_By_Contact__c`, `Submission_Key__c` (External ID, unique), `Invoice_Status__c`, `QBO_Invoice_Id__c` (External ID), `QBO_Invoice_Number__c`, `Invoice_Total__c`, `Invoice_Balance__c`, `Invoice_Due_Date__c`, `Payment_Status__c`, `Last_QBO_Sync__c`, `Sync_Drift__c` (checkbox) |
| OrderItem | `Returned_Quantity__c`, `Return_Status__c`, `Tax_Amount__c` |

**Placed by vs for whom:** `Order.AccountId` = the customer the order is for. `Order.Placed_By_Account__c` / `Placed_By_Contact__c` = the partner (or the customer themselves for direct orders). Both must reach QuickBooks (see the QuickBooks guide for how).

---

## 4. Key design decisions

| # | Decision | Reason |
|---|---|---|
| D1 | Submit is idempotent via a client-generated `Submission_Key__c` | Stops double-click / retry duplicate orders |
| D2 | Invoicing is asynchronous (Platform Event → Queueable) | Confirmation feels immediate; callouts stay out of the user transaction |
| D3 | Four duplicate-invoice guards: unique submission key, "already has QBO Invoice Id" check, QBO `requestid`, and a pre-create query by document number | Defence in depth; each covers a different failure |
| D4 | Persist every step's result before moving on | Retries resume from the last successful step instead of repeating it |
| D5 | Payment sync = webhook (trigger) + fetch (truth) + nightly reconcile (safety net) | Webhooks carry IDs only and can be lost or duplicated |
| D6 | "Overdue" is computed in Salesforce from due date and balance | QuickBooks sends no overdue event |
| D7 | Return money movement happens only after approval, driven by a status change | Meets "self-service submission is not approval" |
| D8 | Returns run as a step machine (credit memo → apply/refund → complete) | Each step is idempotent and resumable |
| D9 | Log everything to `QBO_Sync_Log__c`, but truncate bodies and purge old rows | Dev Edition storage is tiny |

### State machines

**Order invoice status:** `Not Invoiced → Pending → Invoiced` (or `Failed`, which can return to `Pending` on retry)

**Payment status:** `Unpaid → Partially Paid → Paid`, plus `Overdue` (computed) and `Credited` (after a return)

**Return status:** `Requested → Approved → Processing → Credited | Refunded` (or `Rejected`, `Failed`)

---

## 5. Build phases

Each phase ends with a **checkpoint**: paste your work for review before moving on.

### Phase 0 — Environment (about 1 day)
- Create the Salesforce Developer Edition org; verify licences, storage, and features (Org Guide §1).
- Create the Intuit Developer account, app, and sandbox company (QuickBooks Guide §1–2).
- Set up VS Code + Salesforce CLI + Git.
- **Done when:** you can log into both systems and call a QuickBooks endpoint from Postman.
- **Checkpoint:** licence counts and the Postman call working.

### Phase 1 — Data model and security foundation (2–3 days)
- Enable Orders. Create record types, custom fields, custom objects, permission sets.
- Set org-wide defaults for external users to Private.
- Create test data: 2 partners, 3 partner customers, 2 direct customers, 5–8 products.
- **Done when:** the schema exists and you can create an Order manually.
- **Checkpoint:** paste your object/field/relationship design.

### Phase 2 — Portal and ordering (4–6 days)
- Create the Experience Cloud site; set up user onboarding for partners and customers.
- Configure sharing (Sharing Sets or sharing rules, per your licences).
- Build LWCs: catalog, cart, order list, order detail. Build the Apex submission service.
- **Done when:** a partner sees only their customers' orders; a direct customer sees only their own; a second partner sees nothing of theirs.
- **Checkpoint:** the sharing test matrix results, then your `OrderSubmissionService`.

### Phase 3 — QuickBooks connectivity (2–3 days)
- Register the redirect URI, configure Auth Provider, External Credential, Named Credential.
- Build `QboApiClient` (one wrapper for all calls, with 429/5xx handling).
- Sync test customers and items; store the QBO IDs.
- **Done when:** Apex can query a QBO customer and read an item.
- **Checkpoint:** your `QboApiClient`.

### Phase 4 — Async invoicing (4–5 days)
- Platform event, trigger, `QboInvoiceJob`, payload builder, log service.
- Implement all four duplicate guards and failure alerting.
- **Done when:** placing an order creates one matching invoice; forcing a failure produces a visible log entry and a retry produces no duplicate.
- **Checkpoint:** the invoice job and the duplicate-guard tests.

### Phase 5 — Payment sync, overdue, reconciliation (4–5 days)
- Salesforce Site + Apex REST webhook with signature verification.
- Fetch job to update Order payment fields; scheduled overdue job; nightly reconciliation batch.
- **Done when:** paying an invoice in the sandbox updates the Order; a deliberately missed webhook is caught by reconciliation.
- **Checkpoint:** the webhook receiver (security review) and the reconciliation batch.

### Phase 6 — Returns and credit memos (5–7 days)
- Return objects, portal request form with quantity validation, approval process.
- Credit memo job with the step machine; cover unpaid, partially paid, and fully paid cases.
- Update order line return status and the portal view.
- **Done when:** all three invoice states produce correct QuickBooks results, and re-running the job creates no second credit memo.
- **Checkpoint:** the return step machine.

### Phase 7 — Hardening and demo (3–4 days)
- Apex tests with callout mocks, reports/dashboards, purge job, README, demo script.

Rough total: **25–35 working days** part-time, depending on how much QuickBooks refund behaviour needs experimenting.

---

## 6. Test scenarios

**Security**
1. Partner A cannot see Partner B's orders, customers, pricing, or payment status.
2. A direct customer cannot see any partner order.
3. A partner sees payment status for their customers' orders but no account-level financial history.

**Ordering and invoicing**
4. Double-click submit creates one order.
5. Burst of 20–50 orders (scripted) all invoice; none lost.
6. Invoice lines/quantities/prices/tax match the order exactly.
7. QuickBooks returns 429 or 500 → retried, one invoice only.
8. Bad data (unmapped product) → order stays visible as `Failed` with a clear error.
9. Placed-by and for-whom both appear on the invoice.

**Payment sync**
10. Full payment → `Paid`. Partial payment → `Partially Paid` with the correct balance.
11. Past-due date → `Overdue` after the scheduled job.
12. Duplicate/out-of-order webhook → correct final state.
13. Missed webhook → nightly reconciliation corrects it and flags drift.

**Returns**
14. Partial return on an unpaid invoice → balance reduced.
15. Return on a partially paid invoice, including credit larger than the remaining balance.
16. Return on a fully paid invoice → refund/credit path.
17. Retry after failure mid-way → no second credit memo.
18. Returning more than the remaining returnable quantity is blocked.
19. Rejection → no QuickBooks call.

---

## 7. Dev Edition limits and how to live with them

| Limit | Impact | Mitigation |
|---|---|---|
| ~5 MB data storage (about 2,500 records) | Logs and test data fill it quickly | Small data set, truncate log bodies, scheduled purge, avoid storing full payloads |
| Small daily API request cap | Heavy scripted testing can hit it | Use Apex-driven load tests instead of external API loops |
| Few community licences | Limits number and type of test users | Plan personas first (2 partner users, 2 customer users) |
| No CPQ/Revenue Cloud | Discount/tax rules are yours to build | Keep rules simple: pricebook price plus discount percent, tax code per product |
| QuickBooks Builder tier | 500,000 CorePlus reads/month; writes free; sandbox not metered | Prefer webhooks over polling; batch reconciliation queries |

---

## 7b. Questions to confirm with the requirement author

1. On partner orders, **who is billed** in QuickBooks: the partner or the end customer?
2. How is **tax** determined (QuickBooks automated sales tax or a Salesforce-computed amount)?
3. If a return's credit exceeds the remaining unpaid balance, is the excess a refund or left as customer credit?
4. Who is the **approver** for returns (a person, a queue, a role)?
5. Can one customer belong to more than one partner? (Decides whether `Partner_Customer__c` is needed.)
6. Do partners have negotiated pricing, or one shared price book?

---

## 8. Demo script (10 minutes)

1. Log in as Partner A; show the catalog and place an order for one of its customers.
2. Show the instant confirmation, then refresh: invoice number and `Invoiced` status appear.
3. In QuickBooks sandbox, record a partial payment; show the Salesforce Order update.
4. Log in as Partner B; show it cannot see that order.
5. Request a partial return; approve it internally; show the credit memo in QuickBooks and the updated balance in the portal.
6. Force a failure; show the failed sync report and the retry.
