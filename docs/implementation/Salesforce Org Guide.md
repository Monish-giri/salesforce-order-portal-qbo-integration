# Salesforce Developer Edition — Org-Side Guide

Everything to configure and build inside the Salesforce org. Items marked **[VERIFY]** depend on what your particular org includes.

---

## 1. Verify your org first (30 minutes)

Check these before designing anything else, because they shape the security model.

| Check | Where | Why it matters |
|---|---|---|
| User licences: Customer Community, Customer Community Plus, Partner Community (counts) | Setup → Company Information → User Licenses | Decides how partner visibility is done (§4) |
| Data and file storage | Setup → Storage Usage | About 5 MB data; plan for roughly 2,500 records |
| Daily API requests | Setup → Company Information | Limits scripted load tests |
| Orders, Digital Experiences, Platform Events, Sites available | Setup quick find | All required |
| `ReturnOrder` object present? | Object Manager | If yes you may use it instead of custom return objects **[VERIFY]** |
| My Domain deployed | Setup → My Domain | Needed for Experience Cloud and callback URLs |

Then set up tooling: VS Code with Salesforce Extension Pack, Salesforce CLI, a Git repo, and a scratch folder for the Postman collection.

---

## 2. Setup sequence

Follow this order so dependencies exist when you need them.

1. **Enable Orders** (Setup → Order Settings). Enable reduction/other order settings only if needed.
2. **Account record types:** Partner, Direct Customer, Partner Customer.
3. **Custom fields** on Account, Product2, Order, OrderItem (§3).
4. **Custom objects:** `Return_Request__c`, `Return_Request_Line__c`, `QBO_Sync_Log__c` (+ optional).
5. **Platform Events:** `Order_Invoice_Request__e`, `Return_Credit_Request__e`.
6. **Custom Metadata Type:** `QBO_Config__mdt`.
7. **Permission sets** (§4). Page layouts and compact layouts for internal users.
8. **Org-wide defaults** for external users (§4).
9. **Experience Cloud site** (§5).
10. **Integration config** (§6).
11. **Apex, triggers, LWC, Flows** (§7–9).
12. **Reports/dashboards** (§10).

---

## 3. Data model build sheet

### 3.1 Standard objects, fields to add

| Object | API name | Type | Notes |
|---|---|---|---|
| Account | `QBO_Customer_Id__c` | Text, **External ID, Unique** | |
| Account | `Partner_Account__c` | Lookup(Account) | Set on Partner Customer records |
| Product2 | `QBO_Item_Id__c` | Text, External ID | |
| Product2 | `QBO_Tax_Code__c` | Text | |
| Order | `Placed_By_Account__c` | Lookup(Account) | The partner (or the customer for direct orders) |
| Order | `Placed_By_Contact__c` | Lookup(Contact) | |
| Order | `Submission_Key__c` | Text, **External ID, Unique** | Duplicate-submit guard |
| Order | `Invoice_Status__c` | Picklist | Not Invoiced, Pending, Invoiced, Failed |
| Order | `QBO_Invoice_Id__c` | Text, External ID | |
| Order | `QBO_Invoice_Number__c` | Text | |
| Order | `Invoice_Total__c` / `Invoice_Balance__c` | Currency | |
| Order | `Invoice_Due_Date__c` | Date | |
| Order | `Payment_Status__c` | Picklist | Unpaid, Partially Paid, Paid, Overdue, Credited |
| Order | `Last_QBO_Sync__c` | Datetime | |
| Order | `Sync_Drift__c` | Checkbox | Set by reconciliation |
| OrderItem | `Returned_Quantity__c` | Number | |
| OrderItem | `Return_Status__c` | Picklist | None, Requested, Approved, Credited/Refunded, Rejected |
| OrderItem | `Tax_Amount__c` | Currency | |

### 3.2 Custom objects

**`Return_Request__c`** (Name: auto-number `RET-{00000}`)

| Field | Type | Notes |
|---|---|---|
| `Order__c` | Lookup(Order) | Original order |
| `Placed_By_Account__c` | Lookup(Account) | For sharing |
| `Status__c` | Picklist | Requested, Approved, Rejected, Processing, Credited, Refunded, Failed |
| `Reason__c` | Long text | |
| `Submission_Key__c` | Text, External ID, Unique | Duplicate-submit guard |
| `Total_Amount__c` | Roll-up of line amounts | |
| `QBO_CreditMemo_Id__c` | Text, External ID | Written the moment it exists |
| `QBO_Payment_Id__c` | Text | Credit-to-invoice application |
| `QBO_Refund_Id__c` | Text | If a refund receipt was issued |
| `Resolution_Type__c` | Picklist | Applied to Invoice, Refunded, Customer Credit |
| `Current_Step__c` | Picklist | Pending, CreditMemoCreated, Applied/Refunded, Done |

**`Return_Request_Line__c`** — **master-detail** to `Return_Request__c`

Fields: `Order_Item__c` (Lookup), `Quantity__c`, `Unit_Price__c`, `Tax_Amount__c`, `Line_Amount__c` (formula).

**`QBO_Sync_Log__c`** (Name: auto-number `LOG-{000000}`)

Fields: `Related_Record_Id__c`, `Object_Type__c`, `Direction__c` (Outbound/Inbound), `Operation__c`, `Status__c` (Pending, Success, Failed, Retrying), `Request_Id__c`, `HTTP_Status__c`, `Error_Code__c`, `Error_Message__c`, `Retry_Count__c`, `Next_Retry__c`, `Response_Snippet__c` (short, truncated).

**Storage rule:** keep only short snippets, and schedule a purge of successful log rows older than a few days.

### 3.3 Validation rules to add early
- `Return_Request_Line__c.Quantity__c` > 0 and ≤ remaining returnable quantity (needs trigger logic, since it depends on other returns).
- Block edits to `QBO_Invoice_Id__c` by anyone except the integration permission set.
- Order cannot move to Activated without `Placed_By_Account__c` populated for portal orders.

---

## 4. Security and sharing

### 4.1 Org-wide defaults (external access)

| Object | External OWD |
|---|---|
| Account | Private |
| Contact | Private |
| Order | Private |
| Return_Request__c | Private (Controlled by parent for lines) |
| QBO_Sync_Log__c | Private (internal only) |
| Product2 / Pricebook | Visible via pricebook and product access settings only **[VERIFY]** |

### 4.2 Choose the visibility mechanism by licence

| Your licence | Approach |
|---|---|
| **Customer Community** (high-volume) | **Sharing Sets** map user's Contact→Account to the object's account lookups. Create two: one for `Order.AccountId` (customer sees their own orders), one for `Order.Placed_By_Account__c` (partner sees orders it placed). Same for `Return_Request__c.Placed_By_Account__c`. **[VERIFY]** whether one set can map two lookups on one object; otherwise use two sets |
| **Customer Community Plus / Partner Community** | Use portal roles and **sharing rules**; if the end customers are child accounts of the partner, role-hierarchy access can grant the partner visibility over them **[VERIFY]** |
| Anything not covered | **Apex managed sharing:** after creating an Order, insert an `OrderShare` row for the partner's users/role group |

Pick one approach for the whole build and test it with the matrix in §12.

### 4.3 Permission sets
- `Portal_Customer_Access`: create/read Orders, read Product2/PricebookEntry, create Return_Request + lines.
- `Portal_Partner_Access`: same, plus the fields partners may see.
- `Integration_Admin`: edit QBO fields, view logs, run retry actions.
- **Field-level security:** hide `QBO_*` internals from portal users; expose only `Invoice_Status__c`, `Payment_Status__c`, `Invoice_Balance__c`, `Invoice_Due_Date__c` at the order level. Do **not** expose Account-level financial summaries.

### 4.4 Portal-side gotchas **[VERIFY]**
- Portal licences may lack "Activate Orders". If so, the submission service (a `without sharing` Apex class that you write carefully) creates and activates orders after checking the caller's identity.
- Order lines can only be added while the Order is **Draft**; activate after inserting all lines.
- Don't let the browser send an Account Id for "for whom": validate server-side that the target account is one this user is allowed to order for.

---

## 5. Experience Cloud site

1. Setup → Digital Experiences → enable, then **New Site** (Build Your Own, LWR or Aura; pick one and stay with it).
2. Assign profiles/licences; set the site to require login. **Turn off self-registration.**
3. **User onboarding (admin-driven):** create the Account (correct record type) → create the Contact → **Enable Customer/Partner User** on the Contact → assign the permission set → confirm the welcome email. Optionally wrap this in a small Flow for admins.
4. Pages: Home, Catalog, Cart, My Orders, Order Detail, Returns, Return Detail.
5. Guest user: keep it **empty**. No object access.
6. Publish and test as each persona using "Log in to Experience as User".

---

## 6. Integration configuration

### 6.1 QuickBooks connection (OAuth)
1. **Auth Provider:** OpenID Connect type; authorize URL and token URL from the QuickBooks guide §1; Client ID/Secret from Intuit; scope `com.intuit.quickbooks.accounting`. Salesforce shows a **callback URL**; paste it into the Intuit app's redirect URIs.
2. **External Credential** (OAuth 2.0, browser flow) using that Auth Provider, with a Principal; assign the principal to the `Integration_Admin` permission set.
3. **Named Credential** pointing at `https://sandbox-quickbooks.api.intuit.com` using the External Credential.
4. Authenticate the principal once (this is the browser login to the sandbox company).
5. Store the realmId and minorversion in `QBO_Config__mdt`.
6. Apex calls then use `callout:<NamedCredential>/v3/company/<realmId>/...`. No token handling in code.

### 6.2 Webhook receiver (Salesforce Site)
1. Setup → **Sites**: register a domain and create a site (e.g. `qbo_webhook`); set an active home page.
2. Site guest profile: grant access **only** to the webhook Apex class.
3. Apex REST class (`@RestResource(urlMapping='/qbo/webhook')`) reads the **raw body**, verifies `intuit-signature`, logs an inbound row, enqueues processing, and returns 200.
4. Endpoint form: `https://<site-domain>/<site-path>/services/apexrest/qbo/webhook` **[VERIFY]** URL for your site type.
5. Put this URL and the verifier token into the Intuit app's webhook settings.
6. Store the verifier token in `QBO_Config__mdt` for the POC (visible to admins, so not production-grade).

Guest-user notes: the class needs only to validate and enqueue; any DML runs under the guest's context, so keep it minimal and test that the log insert works with the site's default record owner **[VERIFY]**.

---

## 7. Apex component map

Write these yourself; each row is a unit you can paste for review.

| Component | Responsibility |
|---|---|
| `OrderPortalController` (with sharing) | `@AuraEnabled` methods for the LWCs: get catalog, submit order, list orders, order detail |
| `OrderSubmissionService` | Validate caller and target account; upsert on `Submission_Key__c`; create Draft Order + lines; activate; publish `Order_Invoice_Request__e`; return quickly |
| `OrderInvoiceRequestTrigger` | Collect Order Ids from event batches; enqueue jobs in chunks (about 10 orders per job) |
| `QboInvoiceJob` (Queueable, AllowsCallouts) | Skip if `QBO_Invoice_Id__c` exists; ensure customer; build and POST invoice with `requestid`; update Order; log; on retryable error re-enqueue or leave Pending |
| `QboApiClient` | One HTTP wrapper: base URL, headers, JSON parse, 429/5xx/401 handling, error classification |
| `QboPayloadBuilder` | Order/OrderItem → invoice JSON; ReturnRequest → credit memo JSON |
| `QboCustomerService` | Query by DisplayName, create if missing, save `QBO_Customer_Id__c` |
| `QboSyncLogService` | Central insert/update of logs; truncation; retry scheduling |
| `QboWebhookResource` | Signature check, parse events, log, enqueue |
| `QboPaymentSyncJob` | Fetch current invoice(s), overwrite Order payment fields, set `Last_QBO_Sync__c` |
| `OverdueStatusJob` (Schedulable) | Daily: balance > 0 and due date past → Overdue |
| `QboReconciliationBatch` (Schedulable) | Nightly: compare Salesforce vs QuickBooks, set `Sync_Drift__c`, requeue stuck Pending, alert on missing invoices |
| `ReturnRequestService` | Validate quantities; create return; submit for approval; block over-returns |
| `QboCreditMemoJob` (Queueable) | Step machine driven by `Current_Step__c`; resume from the last completed step |
| `LogPurgeJob` (Schedulable) | Delete old successful logs |
| Test classes + `HttpCalloutMock` implementations | Cover each service; mock success, 400, 429, 500, duplicate |

**Rules that will bite you**
- **Callouts before DML.** In a transaction you cannot make a callout after uncommitted DML. In job loops: do the callout, collect results, then do one DML at the end.
- **Callout limits:** 100 per transaction, so chunk your work (each order may need 2–3 calls).
- Platform event triggers can't make callouts directly; the trigger's only job is to enqueue a Queueable.
- Queueable enqueue limits apply from triggers (50 per transaction); if you exceed it, leave the rest `Pending` for the sweeper.
- Use `WITH USER_MODE`/`with sharing` on portal-facing code; use `without sharing` only inside narrow, reviewed service methods.
- Bulkify everything, even if volume is small.

---

## 8. LWC component map

| Component | Purpose |
|---|---|
| `productCatalog` | Product list with current price, search, add to cart |
| `orderCart` | Line editing, totals, generates the `Submission_Key__c` (UUID) once per checkout, disables the button while submitting |
| `orderList` | Orders visible to the user with invoice/payment status |
| `orderDetail` | Lines, invoice number, balance, due date, per-line return status, return button |
| `returnRequestForm` | Pick lines and quantities (validated against returnable amounts), reason, submit |
| `returnList` / `returnDetail` | Status (requested, approved, rejected, refunded) and the effect on the amount owed |
| `syncStatusBadge` | Small reusable status chip |

Expose components in the site builder; test each as every persona.

---

## 9. Flows and automation

| Automation | Type | Notes |
|---|---|---|
| Return approval | **Approval Process** on `Return_Request__c` (or Flow approval) | Entry: Status = Requested. Approver: a queue or named user. Approve → Status = Approved (fires the credit job). Reject → Rejected. Portal users don't approve |
| Submit for approval | Apex in `ReturnRequestService` | Portal users can't submit themselves, so the service does it |
| Approved → credit job | Record-triggered Flow or trigger → publish `Return_Credit_Request__e` | Fires only on transition to Approved |
| Failure alerting | Flow on `QBO_Sync_Log__c` (Status = Failed) | Email/notification to the responsible user or queue |
| Invoice-failed visibility | Report + Order list view "Invoice Failed" | Requirement: no silent failures |
| Order line return status | Trigger/Flow on return completion | Updates `OrderItem.Returned_Quantity__c` and status |

---

## 10. Reports and dashboards

- Orders by invoice status (highlight Failed and Pending older than 15 minutes)
- Unpaid / Partially Paid / Overdue orders, with balance
- Orders flagged `Sync_Drift__c`
- Returns by status, and returns awaiting approval
- Sync log failures by error code
- Dashboard: "Integration health" combining the above

---

## 11. Limits and gotchas cheat-sheet

| Topic | Watch for |
|---|---|
| Storage | ~2,500 records total; each order with lines and logs consumes ~10 records. Purge logs |
| Callouts | 100 per transaction; 120 s total; long-running concurrent callout limit org-wide |
| Platform events | Callouts not allowed in the trigger; use Queueable |
| Sharing | Portal users' access is only as good as your OWD + sharing mechanism; test negative cases |
| Order activation | Lines only while Draft |
| Guest user | Minimal class access; no object permissions |
| Secrets | Verifier token in metadata is POC-only |
| Governor limits | Bulkify; avoid SOQL/DML in loops |
| Field History | Max 20 tracked fields per object; track `Invoice_Status__c`, `Payment_Status__c`, `Status__c` |

---

## 12. Test data and verification

**Personas (small, due to licences):** Partner A user, Partner B user, Direct Customer user, plus an internal admin/approver.

**Seed data:** 2 partners, 3 partner customers (2 under A, 1 under B), 2 direct customers, 5–8 products mapped to QBO items.

**Sharing test matrix (run before any integration work)**

| Logged in as | Should see | Should NOT see |
|---|---|---|
| Partner A | Its own and its customers' orders/returns | Any Partner B or direct-customer order |
| Partner B | Same, for B | Anything of A |
| Direct Customer | Own orders/returns | Any partner order |
| Guest | Nothing | Everything |

**Final verification checklist**
- [ ] Sharing matrix passes
- [ ] Double-submit creates one order
- [ ] Order → invoice within moments; fields match
- [ ] Failed callout visible; retry creates no duplicate
- [ ] Payment in QuickBooks updates the Order; overdue job works
- [ ] Missed webhook caught by reconciliation
- [ ] Partial return: approval → credit memo → correct balance
- [ ] Return on a paid invoice handled per the agreed rule
- [ ] Re-running the credit job creates no second credit memo
- [ ] Apex tests pass with mocks
- [ ] Storage is under control (purge job scheduled)

---

## 13. Source control and housekeeping

- Create an SFDX project; retrieve all metadata; commit early and often.
- One branch per phase; tag at each checkpoint.
- Keep a `README` with: setup steps, licence assumptions, how to re-authenticate QuickBooks, how to reset test data.
