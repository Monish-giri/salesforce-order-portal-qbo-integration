# QuickBooks Online — Development-Side Guide

Everything you set up and learn on the QuickBooks/Intuit side before and while writing Salesforce code. Items marked **[VERIFY]** depend on real sandbox behaviour or current Intuit docs, so test them early.

**Recommendation:** prove every call in Postman or Intuit's API Explorer first. Only then translate it into Apex.

---

## 1. Accounts and app setup

1. Sign up at the Intuit Developer portal (free).
2. Dashboard → **Create an app** → *QuickBooks Online and Payments*.
3. Select the scope **`com.intuit.quickbooks.accounting`** (add payments scopes only if needed; not required here).
4. Under **Development** settings, note the **Client ID** and **Client Secret**.
5. Add a **Redirect URI**. It must match exactly what Salesforce will use (the Auth Provider callback URL, see the Org Guide §6). You can add it after you create the Salesforce Auth Provider.
6. Intuit provisions a **sandbox company** automatically (you can have several). Note its **Company ID (realmId)** from the dashboard. You will need it in every API URL.

**Environment facts**

| Item | Value |
|---|---|
| Sandbox API base | `https://sandbox-quickbooks.api.intuit.com/v3/company/{realmId}/` |
| Production API base | `https://quickbooks.api.intuit.com/v3/company/{realmId}/` |
| Authorize URL | `https://appcenter.intuit.com/connect/oauth2` |
| Token URL | `https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer` |
| Access token lifetime | About 1 hour |
| Refresh token | Long-lived (about 100 days) but **rotates**: every refresh can return a new one **[VERIFY]** |
| Production keys | Require Intuit's app assessment; not needed for this POC |

**Free-tier rules (Builder tier):** write calls (create invoice, credit memo, payment) are unlimited; read calls are metered at 500,000 per month in production; **sandbox calls are not metered**. Throttling applies in both: about 500 requests/min per company, 10 concurrent requests, and about 40 batch requests/min (10 payloads per batch). Over the limit you get HTTP 429.

---

## 2. Prepare the sandbox company

Do this in the QuickBooks sandbox UI.

| Setting | Action | Why |
|---|---|---|
| Custom transaction numbers | Turn **on** (Account and Settings → Sales) | So the API can set your own invoice number (`DocNumber`) **[VERIFY]** |
| Sales tax | Decide now: automated sales tax on or off | Changes how tax appears on invoices (see §6) |
| Products and services | Create 5–8 items of type **Service** or **Non-inventory** | Avoid inventory-tracked items; inventory is out of scope |
| Income account | Make sure each item points to a sales income account | Required for invoice lines |
| Payment method and deposit account | Ensure a payment method (e.g. Check) and *Undeposited Funds* exist | Needed to record test payments |
| Sample customers | Create 2–3 to experiment with | Used in the Postman phase |

Keep a mapping sheet: **Salesforce Product2 → QBO Item Id**, and **Salesforce Account → QBO Customer Id**. These become `QBO_Item_Id__c` and `QBO_Customer_Id__c`.

---

## 3. Authentication

**Flow:** OAuth 2.0 authorization code. A human authorizes once (a browser login to the sandbox company); afterwards the platform refreshes tokens.

Practical points:
- Every API call uses `Authorization: Bearer <access_token>`, `Accept: application/json`, `Content-Type: application/json`.
- The **realmId is returned in the redirect URL** during authorization. Salesforce's Auth Provider flow does not surface it, so **store it in `QBO_Config__mdt`** (copy it from the dashboard).
- Because refresh tokens rotate, you must let Salesforce's credential mechanism handle refresh (External/Named Credential). Do not hand-roll token storage in a normal field.
- If the integration is idle for a very long time (about 100 days) the refresh token dies and you must re-authorize.
- Add a `minorversion` query parameter (use the latest one in Intuit's docs) to every call for predictable field behaviour.

**Postman setup:** use the Intuit OAuth 2.0 Playground (in the developer portal) to get a first access token for testing. Then hit the CompanyInfo endpoint as a smoke test:
`GET /v3/company/{realmId}/companyinfo/{realmId}`

---

## 4. Entities and calls you will use

### 4.1 Customer

- **Query:** `GET .../query?query=select * from Customer where DisplayName = 'Acme'` (URL-encode).
- **Create:** `POST .../customer`
- **DisplayName must be unique** across customers, vendors, and employees; a clash returns a "Duplicate Name Exists" error (code around 6240). Build the name deterministically, e.g. `"<Account Name> (SF-<last 6 of Id>)"`.
- **Sub-customers:** a customer can have a `ParentRef` (set `Job: true`/`BillWithParent`) **[VERIFY]**. This is one option for representing partner → end customer.

### 4.2 Item

Usually **created by hand** in QuickBooks, then mapped. Read with `select * from Item where Active = true` when you build your mapping.

### 4.3 Invoice (create)

`POST .../invoice?minorversion=<latest>&requestid=<unique id>`

Reference shape:

```json
{
  "CustomerRef": { "value": "58" },
  "DocNumber": "SO-000123",
  "TxnDate": "2026-09-29",
  "DueDate": "2026-10-29",
  "PrivateNote": "SF Order 801xx...; Placed by partner: Acme Partners",
  "CustomerMemo": { "value": "Order SO-000123" },
  "Line": [
    {
      "DetailType": "SalesItemLineDetail",
      "Amount": 200.00,
      "Description": "Widget",
      "SalesItemLineDetail": {
        "ItemRef": { "value": "12" },
        "Qty": 2,
        "UnitPrice": 100,
        "TaxCodeRef": { "value": "TAX" }
      }
    }
  ]
}
```

Rules to respect:
- `Amount` must equal `Qty × UnitPrice` (after any discount handling).
- `DocNumber` has a length limit (about 21 characters) and is only honoured when custom transaction numbers are on.
- Store the returned `Id`, `DocNumber`, `SyncToken`, `TotalAmt`, `Balance`, `DueDate` back on the Order.

### 4.4 Invoice (read)

`GET .../invoice/{id}` returns `TotalAmt`, `Balance`, `DueDate`, `SyncToken`, and `LinkedTxn` (payments/credit memos applied).

**Deriving payment status in Salesforce**

| QuickBooks state | Salesforce `Payment_Status__c` |
|---|---|
| `Balance = TotalAmt` | Unpaid |
| `0 < Balance < TotalAmt` | Partially Paid |
| `Balance = 0` | Paid |
| `Balance > 0` and `DueDate < today` | Overdue (computed by the scheduled job) |

### 4.5 Credit memo, apply, refund (returns)

Three situations, three different QuickBooks shapes. **Test all three in Postman before designing the return object flow. [VERIFY]**

| Original invoice state | Expected QuickBooks approach |
|---|---|
| **Unpaid or partly paid** | Create a **CreditMemo** with the returned lines, then create a **Payment** that links the credit memo to the invoice so the invoice balance drops |
| **Fully paid** | Create a **CreditMemo**, then issue the refund (a **RefundReceipt** with a deposit/refund account) or leave it as customer credit |
| **Credit larger than the remaining balance** | Apply up to the balance; the excess is a business decision (customer credit vs refund). Confirm with the requirement author |

Reference shape to apply a credit memo to an invoice (experiment with it):

```json
{
  "CustomerRef": { "value": "58" },
  "TotalAmt": 0,
  "Line": [
    { "Amount": 50.00, "LinkedTxn": [ { "TxnId": "<invoiceId>",    "TxnType": "Invoice" } ] },
    { "Amount": 50.00, "LinkedTxn": [ { "TxnId": "<creditMemoId>", "TxnType": "CreditMemo" } ] }
  ]
}
```

The invoice and the credit memo go on **separate lines with the same amount**, and `TotalAmt` is 0 because no cash moves. A payment linked only to a credit memo is rejected. The amount applied cannot exceed the invoice's outstanding balance, so apply the smaller of the credit and the balance. The Postman collection (folder 5A) exercises this.

Important: a refund object may not carry a formal link back to the invoice. If so, record the link yourself in `PrivateNote`/`DocNumber` (e.g. `RET-00012 for SO-000123`) **and** in Salesforce (`Return_Request__c` stores the IDs).

### 4.6 Payment (for testing)

Simulate payments to drive your webhook: `POST .../payment` with `CustomerRef`, `TotalAmt`, and a line linking to the invoice, or just record a payment in the sandbox UI.

### 4.7 Updates

Updates require the object's current **`SyncToken`**; a stale one gives a "stale object" error (around 5010). Use sparse updates (`"sparse": true`) to change only some fields.

---

## 5. Idempotency (no duplicate invoices or credit memos)

QuickBooks-side tools you can use:

| Guard | How |
|---|---|
| **`requestid`** query parameter | Intuit documents that a repeated `requestid` returns the **original response** instead of repeating the operation. It must be **unique per company** and at most **50 characters** (36 for batch operations). Use a stable key: `INV-<order number>`, `CM-<return number>`, and send it on every write. **[VERIFY]** how long QuickBooks remembers a request id (the documentation does not state it) |
| **Pre-create query** | Before creating, query for an existing document whose `DocNumber` (or note) matches the Salesforce reference |
| **Store first, act second** | Write the returned QBO Id to Salesforce immediately; on retry, if the Id exists, skip creation |

Use all three together: `requestid` handles network retries, the query handles a lost response, and the stored Id handles everything after.

---

## 6. Representing "placed by" vs "for whom", and tax

**Placed by vs for whom.** Options, in order of preference **[VERIFY each]**:
1. **Sub-customer:** the end customer is a sub-customer of the partner customer. Invoice `CustomerRef` is the sub-customer; the partner is the parent.
2. **Bill the end customer directly** and put the partner in `PrivateNote`/`CustomerMemo`.
3. Use a **Class** to tag the partner (QuickBooks tiers cap the number of classes, roughly 40 combined classes/locations on Plus).

Whichever you choose, also carry the same reference on any credit memo.

**Tax.** Two approaches:
- **Automated sales tax on:** lines carry a tax code (`TAX`/`NON`) and QuickBooks computes tax; your Salesforce tax field must be a display of what QuickBooks returned.
- **Tax computed in Salesforce:** pass explicit tax detail so totals match.

For a POC, pick one, invoice a few sample orders, and confirm the totals agree before building further.

---

## 7. Webhooks

**Setup (Developer portal → your app → Webhooks):**
1. Enter the public **HTTPS** endpoint (your Salesforce Site URL for the Apex REST class; see Org Guide §6).
2. Subscribe to entities: **Invoice**, **Payment**, **CreditMemo**, **RefundReceipt** (events: Create, Update, Delete).
3. Copy the **Verifier Token** (used to validate signatures).

**Payload shape (IDs only, no invoice data):**

```json
{
  "eventNotifications": [{
    "realmId": "123146...",
    "dataChangeEvent": {
      "entities": [
        { "name": "Invoice", "id": "145", "operation": "Update", "lastUpdated": "2026-09-29T10:00:00Z" }
      ]
    }
  }]
}
```

**Validation:** compute **HMAC-SHA256 of the raw request body** using the verifier token, Base64-encode it, and compare it with the `intuit-signature` header. Reject on mismatch.

**Behaviour to design for**
- Respond `200` quickly; do the work asynchronously.
- Events can arrive **duplicated or out of order**, so on each event fetch the current object from QuickBooks and overwrite Salesforce with the latest state. Never apply "deltas".
- For Payment/CreditMemo events, read the object to find the linked invoice(s), then refresh those.
- Webhooks can be missed, so pair them with the reconciliation job.

**Fallback: Change Data Capture.** `GET .../cdc?entities=Invoice,Payment&changedSince=<timestamp>` returns changes since a time. Ideal for the nightly reconciliation.

---

## 8. Error handling reference

| Situation | Typical signal | Response |
|---|---|---|
| Throttled | HTTP 429 | Retry with exponential backoff; lower concurrency |
| Access token expired | HTTP 401 | Let the credential refresh; retry once |
| Validation problem (bad item, tax, amount) | HTTP 400 | **Do not retry blindly**; log, set `Failed`, alert a human |
| Duplicate name | Error around 6240 | Query for the existing customer and reuse it |
| Stale object | Error around 5010 | Re-read for the new `SyncToken`, retry |
| QuickBooks outage | HTTP 5xx / timeout | Retry later; keep status `Pending` |

Classify errors as **retryable** (429, 5xx, timeout, 401 once) or **terminal** (400 validation). Only retryable errors auto-retry, and terminal ones go to a human.

---

## 9. Postman rehearsal checklist (do before any Apex)

- [ ] Get an access token via the Playground
- [ ] `GET companyinfo` succeeds
- [ ] Query a customer; create a customer; create the same name again (see the duplicate error)
- [ ] Query items; note their Ids
- [ ] Create an invoice with 2 lines; check `DocNumber`, `TotalAmt`, tax
- [ ] Repeat the create with the **same `requestid`**; confirm no second invoice **[VERIFY]**
- [ ] Record a partial payment; re-read the invoice; see `Balance`
- [ ] Create a credit memo for one line; apply it to an unpaid invoice with a Payment
- [ ] Repeat on a fully paid invoice with a refund path
- [ ] Register the webhook and see a real notification arrive (needs the Salesforce Site from Org Guide §6)

## 10. Deliverables from this side

1. Working Postman collection covering the above.
2. Mapping sheet: Product ↔ Item Id, Account ↔ Customer Id.
3. Decisions recorded for: tax approach, partner representation, refund-vs-credit rule.
4. Values for `QBO_Config__mdt`: realmId, base URL, minorversion, webhook verifier token (POC only).

---

## 11. Verified against Intuit documentation (September 2026)

| Topic | What the documentation says | Where it is reflected |
|---|---|---|
| Minor version | Examples use `minorversion=75`; send it on every call | Postman variable `minorVersion` |
| Request IDs | Unique per company, max 50 characters, replay returns the original response | §5, Postman folder 3 and 5 replay requests |
| Throttling | About 500 requests/min and 10 concurrent per company; about 40 batch requests/min with 10 payloads each | §1 |
| Apply a credit memo | Payment with `TotalAmt` 0, one line linking the invoice and a separate line linking the credit memo, with equal amounts. A payment linked only to a credit memo is rejected | §4.5, Postman 5A.5 |
| Refund receipt | Requires `DepositToAccountRef` and at least one line; no documented link back to an invoice | §4.5, Postman 5B.2 and 5B.3 |
| Duplicate document numbers | Integration guides report error 6140 when custom transaction numbers are on. Treat as unconfirmed until Postman request 3.5 shows it in your sandbox | §5 |
| Update conflicts | Updates need the current `SyncToken`; stale tokens fail | §4.7, Postman 7.3 |

## 12. Postman collection

`QBO-Order-Portal-POC.postman_collection.json` runs every call in this guide in order: token refresh, customers (including the partner sub-customer), invoice create with `requestid` and replay, partial/full/overdue payments, credit memo application, refund receipt, Change Data Capture, simulated webhooks and error cases. Fill `realmId`, `accessToken`, `refreshToken`, `clientId`, `clientSecret` as *current values* and run folders 0 to 7 in order.