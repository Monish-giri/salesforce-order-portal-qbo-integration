# Order Portal with QuickBooks Online Invoicing, B2B/B2C Experiences, Returns and Razorpay Payments — Implementation Guide

**Environment:** Salesforce Developer Edition + Experience Cloud (LWR) + QuickBooks Online (Intuit Developer sandbox, free Builder tier) + Razorpay Test Mode  
**Companion documents:** `02-QuickBooks-Online-Development-Guide.md` and `03-Salesforce-Developer-Edition-Org-Guide.md`  
**Source requirement:** Order Portal with QuickBooks Online Invoicing – Business Requirement (Sep 21, 2026), extended by the agreed B2B/B2C, self-service returns, early-payment discount, and Razorpay payment requirements.

This guide is the master implementation plan. It defines the architecture, data model, security model, B2B/B2C experience, pricing, early-payment discount, payment integration, returns, build phases, and test plan. The companion documents hold system-specific setup detail. Where a detail depends on the org, licence, QuickBooks behaviour, Razorpay merchant configuration, or a sandbox experiment, it is marked **[VERIFY]**.

**Implementation rule:** Do not move away from this guide or the companion guides without first recording and agreeing the design change. Existing working functionality remains the baseline; new work must extend it rather than replace working integrations unnecessarily.

---

## 1. Goal and definition of done

Build a working proof of concept where:

1. A direct customer or business/partner user logs into a single Experience Cloud portal, browses products, and places an order.
2. The same Experience Cloud site provides different experiences for B2B and B2C users based on the authenticated user's business context.
3. B2B users receive a business-oriented catalog, B2B pricebook, business information, quantity-oriented purchasing features, payment terms, early-payment discount information, and other business features that are not exposed to B2C users.
4. B2C users receive a simpler retail-oriented catalog, B2C pricebook, checkout, order history, payment and return experience.
5. The order is saved in Salesforce (`Order` + `OrderItem`) and the user gets an immediate confirmation.
6. Within moments, a matching invoice exists in QuickBooks Online, traceable to the Salesforce Order, with no duplicates even on retry.
7. Payment status from QuickBooks continues to synchronize to Salesforce for invoices paid outside the new gateway.
8. B2B users can see their applicable payment due date and an early-payment discount that is highest during the first seven days after invoice issuance and decreases as payment is delayed. The exact discount percentages are configurable and are not hard-coded in the UI.
9. B2B users can make an online payment through Razorpay. Razorpay is the payment gateway; Salesforce is the portal/business-logic layer; QuickBooks remains the accounting system.
10. A verified Razorpay payment is synchronized to the corresponding QuickBooks invoice and Salesforce Order exactly once.
11. A user can request a full or partial return from the portal. An internal approver approves or rejects the request. Approved returns are processed through the existing QuickBooks credit memo/refund step machine.
12. For orders actually paid through Razorpay, a cash refund must use the Razorpay refund flow and must also be reconciled with the QuickBooks accounting transaction and Salesforce return record.
13. Every integration failure is visible through `QBO_Sync_Log__c` or the appropriate payment/return integration log, every important operation is auditable, and retries are idempotent.
14. A partner/business user can never see another party's orders, prices, payment information, return information, or customer data unless explicit sharing rules grant that access.

### Explicit POC limitations

- Salesforce Developer Edition storage and API limits.
- QuickBooks sandbox/test environment rather than production credentials.
- Razorpay Test Mode rather than live merchant processing.
- Multi-currency is out of scope unless explicitly added later.
- Subscriptions and recurring billing are out of scope.
- Inventory reservation and returned-goods inventory processing are out of scope unless explicitly added later.
- The early-payment discount is a configurable business rule, not a full CPQ/Revenue Cloud pricing engine.
- B2B and B2C are implemented in one Experience Cloud site, not two separate sites.

---

## 2. Architecture

```text
                    EXPERIENCE CLOUD — ONE LWR SITE
                              |
                 +------------+-------------+
                 |                          |
            B2B Experience             B2C Experience
                 |                          |
                 +------------+-------------+
                              |
                    Portal Shell / LWC
                              |
                 +------------+-------------+
                 |                          |
              Catalog                    My Orders
                 |                          |
              Cart                  Returns / Payment
                 |                          |
                 +------------+-------------+
                              |
                    Apex business services
                              |
             +----------------+----------------+
             |                                 |
      OrderSubmissionService          ReturnRequestService
             |                                 |
             v                                 v
       Salesforce Order                Return_Request__c
       + OrderItem                     + Return_Request_Line__c
             |                                 |
             v                                 v
   Order_Invoice_Request__e        Return_Credit_Request__e
             |                                 |
             v                                 v
       QboInvoiceJob                  QboCreditMemoJob
             |                                 |
             +---------------+----------------+
                             |
                       QUICKBOOKS ONLINE
                             |
              invoice / payment / credit memo
                             |
                    webhook + fetch + reconcile
                             |
                       Salesforce Order

B2B/B2C online payment path:

 Salesforce Order / QBO Invoice
          |
          v
 RazorpayPaymentService (Apex)
          |
          v
 Razorpay Orders API
          |
          v
 Razorpay Checkout
          |
          v
 Signature verification + webhook
          |
          v
 Salesforce payment transaction
          |
          +----> QuickBooks Payment linked to Invoice
          |
          +----> Return refund, when applicable
```

### Architectural responsibilities

| System | Responsibility |
|---|---|
| Experience Cloud / LWC | Portal presentation, catalog, cart, order/return/payment UX |
| Salesforce Apex | Authorization, pricing resolution, discount calculation, payment orchestration, integration state, idempotency |
| Salesforce data model | Authoritative portal/order/return/payment reference data and audit trail |
| QuickBooks Online | Accounting, invoices, customer balances, accounting payments, credit memos and accounting-side refund/credit treatment |
| Razorpay | Online payment collection and gateway-side refunds for Razorpay-paid transactions |
| Platform Events | Decouple order submission/return processing from external callouts |
| Scheduled/Queueable jobs | Async integration, retries, reconciliation and overdue processing |

### Key payment principle

**Razorpay is not a replacement for QuickBooks.** It is the online payment gateway. Salesforce coordinates the customer-facing payment flow and stores the gateway references. QuickBooks remains the accounting source for invoices and accounting payments.

A successful Razorpay payment must therefore result in two synchronized outcomes:

1. A verified gateway transaction in Razorpay/Salesforce.
2. An accounting payment linked to the correct QuickBooks invoice.

The browser callback alone must never be treated as proof of payment. Razorpay's documented flow uses a server-created order, Checkout, signature verification and payment-status verification; webhooks should drive asynchronous automation, with API verification used when an immediate user-facing confirmation is required. **[VERIFY current API version and enabled methods during implementation.]**

---

## 3. B2B and B2C experience strategy

### 3.1 One site, different experiences

Use the existing single Experience Cloud LWR site. **Do not create separate B2B and B2C sites for this POC.**

The authenticated user's Salesforce business context determines the experience. The existing implementation already distinguishes `Partner` and `Customer` audiences in the catalog/checkout services. That foundation should be extended rather than duplicated.

The experience is separated at three levels:

1. **Server-side business context** — Apex determines the user's authorized audience.
2. **Data and pricing** — Apex resolves the correct catalog and pricebook and validates the selected records server-side.
3. **Presentation** — the LWC shell displays B2B or B2C features according to the resolved context. Experience Builder visibility can additionally be used for page/component differences where appropriate.

**Security rule:** UI visibility is not a security boundary. Apex authorization, object permissions, sharing, and server-side pricebook validation remain mandatory.

### 3.2 Audience model

| Existing account context | Portal audience | Initial experience |
|---|---|---|
| Partner account / business buyer | `Partner` | B2B |
| Direct customer | `Customer` | B2C |
| Partner Customer | `Customer` initially | B2C-style unless a later business rule assigns B2B access |

If the business later requires a third experience for partner end customers, add a third audience explicitly rather than overloading the existing two.

### 3.3 B2B experience

The B2B portal should expose useful business information without turning the page into an internal financial dashboard.

Recommended B2B features:

- B2B-specific product catalog.
- B2B pricebook.
- Product code/SKU search.
- Product specifications and technical information.
- Quantity-aware ordering.
- Volume/quantity price breaks where configured.
- Recommended retail price where commercially appropriate.
- Estimated gross resale margin based on configured recommended retail price and B2B acquisition price.
- Payment terms and invoice due date.
- Early-payment discount window and current eligible discount.
- Amount currently payable through Razorpay.
- Invoice/payment history.
- Reorder from previous orders.
- Customer selection where a partner is authorized to order for one of its customer accounts.
- Return request and return status.
- Clear business account identity and ordering context.
- Optional purchase-order/reference number support if added to the data model.

### 3.4 B2C experience

The B2C portal should prioritize simplicity.

Recommended B2C features:

- B2C retail pricebook.
- Product images and simple product descriptions.
- Category/search/filter experience.
- Cart and streamlined checkout.
- Online payment through Razorpay.
- Order history and order detail.
- Payment status.
- Self-service full/partial return request.
- Return/refund status.
- Reorder capability where useful.

B2C users must **not** see B2B-only commercial information such as reseller purchase price, estimated margin, partner/customer selection, or internal business pricing rules.

### 3.5 Commerce patterns used as design references

The B2B design is informed by established commerce patterns such as company/business profiles, customer-specific catalogs and pricing, quantity rules, volume pricing, payment terms, reordering, and self-service returns. Shopify's current B2B documentation is a useful reference for these patterns; it supports B2B and D2C through one store and describes company-level pricing, catalogs, payment terms, quantity rules, reorders and self-service returns. These are reference patterns only; this implementation remains Salesforce-native.

B2C design follows common direct-to-consumer patterns: clean product discovery, simple checkout, clear order history, online payment, easy return initiation and clear refund status.

---

## 4. Data model

### 4.1 Standard objects used

| Object | Role |
|---|---|
| Account | Partner, Direct Customer, and Partner Customer business context |
| Contact | Portal user and business/customer contact |
| User | Experience Cloud login |
| Product2 | Product master |
| Pricebook2 | B2B/B2C pricing catalogs |
| PricebookEntry | Product price within an audience pricebook |
| Order | Authoritative sales/order record |
| OrderItem | Order lines and returnable quantities |

### 4.2 Custom objects

| Object | Purpose |
|---|---|
| `Return_Request__c` | Return header, reason, status, approval and QBO/Razorpay references |
| `Return_Request_Line__c` | Return line, OrderItem, quantity and amount |
| `QBO_Sync_Log__c` | Integration events, errors, retry/audit information |
| `Razorpay_Payment__c` | Recommended payment transaction record for gateway IDs/statuses; create if not already present |
| `Partner_Customer__c` *(optional)* | Junction, only if one customer can have multiple partners |
| `QBO_Payment__c` *(optional)* | Only if per-payment history is required beyond the gateway transaction object |

### 4.3 Platform events

Existing:

- `Order_Invoice_Request__e`
- `Return_Credit_Request__e`

Add a payment event only if the implementation benefits from asynchronous processing:

- `Razorpay_Payment_Request__e` *(optional)*

### 4.4 Custom Metadata

Existing `QBO_Config__mdt` remains responsible for QuickBooks integration configuration.

Existing `Portal_Catalog_Config__mdt` remains the configuration point for portal audience/catalog/pricebook selection.

Add configuration for the new commercial/payment rules rather than embedding them in Apex.

Recommended:

- `Payment_Gateway_Config__mdt`
- `B2B_Early_Payment_Discount__mdt`

Example early-payment metadata:

| Field | Example |
|---|---|
| Audience | Partner |
| Day From | 1 |
| Day To | 7 |
| Discount Percent | configurable |
| Active | true |
| Priority | 1 |

### 4.5 Key fields

**Account**

- `QBO_Customer_Id__c` — External ID, unique.
- `Partner_Account__c` — lookup to Account for Partner Customer relationships.
- `IsPartner` — existing Salesforce field used to identify partner context.

**Product2**

- `QBO_Item_Id__c` — External ID.
- `QBO_Tax_Code__c`.
- `Recommended_Retail_Price__c` — proposed field for B2B margin display, if not already present.

**Order**

- `Placed_By_Account__c`.
- `Placed_By_Contact__c`.
- `Submission_Key__c` — External ID, unique.
- `Invoice_Status__c`.
- `QBO_Invoice_Id__c` — External ID.
- `QBO_Invoice_Number__c`.
- `Invoice_Total__c`.
- `Invoice_Balance__c`.
- `Invoice_Due_Date__c`.
- `Payment_Status__c`.
- `Last_QBO_Sync__c`.
- `Sync_Drift__c`.
- `Razorpay_Order_Id__c`.
- `Razorpay_Payment_Id__c`.
- `Payment_Gateway_Status__c`.
- `Payment_Amount__c`.
- `Early_Payment_Discount__c`.
- `Early_Payment_Discount_Percent__c`.
- `Discount_Eligibility_End__c` — optional snapshot.

**OrderItem**

- `Returned_Quantity__c`.
- `Return_Status__c`.
- `Tax_Amount__c`.
- `B2B_Margin_Amount__c` — optional audit snapshot.

**Return_Request__c**

- `Order__c`.
- `Placed_By_Account__c`.
- `Reason__c`.
- `Resolution_Type__c`.
- `Status__c`.
- `Current_Step__c`.
- `QBO_CreditMemo_Id__c`.
- `QBO_Payment_Id__c`.
- `QBO_Refund_Id__c`.
- `Razorpay_Payment_Id__c`.
- `Razorpay_Refund_Id__c`.
- `Refund_Amount__c`.

**Razorpay_Payment__c** (if created)

- Salesforce Order lookup.
- Razorpay Order ID.
- Razorpay Payment ID.
- Payment status.
- Amount requested.
- Amount captured.
- Currency.
- Payment method.
- Gateway receipt/reference.
- Signature verification status.
- Webhook event ID.
- Created/updated timestamps.

Do not store card numbers, CVV, UPI credentials, or other sensitive payment credentials in Salesforce.

---

## 5. Pricing and B2B margin model

### 5.1 Separate pricebooks

The initial pricing model uses two Salesforce pricebooks:

| Audience | Pricebook |
|---|---|
| B2B / Partner | `B2B Partner Pricebook` |
| B2C / Customer | `B2C Retail Pricebook` |

The actual names can be changed, but the audience-to-pricebook mapping must remain configuration-driven.

The browser must never be trusted to decide the pricebook or unit price. Apex resolves the authorized audience, resolves the configured pricebook, and verifies that every submitted `PricebookEntry` belongs to the configured active pricebook.

The existing `OrderSubmissionService` already follows this security pattern: it resolves the audience, resolves the configured pricebook, queries active PricebookEntries from that pricebook, and uses the server-side `UnitPrice` when creating OrderItems. Preserve this model.

### 5.2 B2B margin display

For B2B users, display an indicative resale margin only when a recommended retail price is available and the user is authorized to see it.

Example:

```text
B2B Price:             ₹4,000
Recommended Retail:   ₹5,000
Estimated Margin:     ₹1,000
Estimated Margin %:       20%
```

Formula for a simple gross margin display:

```text
Margin Amount = Recommended Retail Price - B2B Purchase Price
Margin %       = Margin Amount / Recommended Retail Price × 100
```

This is an **estimated gross resale margin**, not a guaranteed profit. It excludes taxes, shipping, operating expenses, customer-specific discounts, and other commercial costs unless explicitly included.

### 5.3 Volume pricing

Volume pricing can be implemented later using multiple PricebookEntries or a small dedicated pricing rule. Do not introduce a complex CPQ/Revenue Cloud-style pricing engine unless required by the business.

### 5.4 Price integrity

The following must be server-side:

- audience resolution;
- pricebook resolution;
- product eligibility;
- unit price;
- quantity rules;
- discount eligibility;
- final payable amount.

The LWC may display these values but cannot be the source of truth.

---

## 6. B2B early-payment discount

### 6.1 Business rule

B2B customers receive a larger discount when they pay early. The discount decreases as payment is delayed.

The existing QuickBooks payment due date remains the payment due date. The early-payment discount is an incentive within that payment term; it does not automatically change the invoice due date.

Initial business structure:

| Payment timing | Discount |
|---|---:|
| Days 1–7 after invoice issuance | Highest |
| Days 8–14 | Lower |
| Day 15 through the existing due date | Lower or zero, according to configuration |
| After due date | No early-payment discount |

**The percentages are placeholders for configuration. The final commercial percentages must be supplied before production use.**

### 6.2 Date calculation

Use the invoice issue/transaction date stored from QuickBooks, not the browser's local clock.

```text
Days Elapsed = Payment Date - Invoice Issue Date
```

The applicable discount tier is selected from `B2B_Early_Payment_Discount__mdt`.

### 6.3 Payment quote

When a B2B user clicks **Pay Now**:

1. Salesforce reads the latest invoice balance.
2. Salesforce determines whether the invoice is still eligible for an early-payment discount.
3. Salesforce calculates the discount using the configured tier.
4. Salesforce calculates the final payable amount.
5. Salesforce creates a Razorpay Order for that exact amount.
6. Salesforce stores the calculated discount snapshot and Razorpay Order ID.
7. Razorpay Checkout opens.

The client must never be allowed to modify the payable amount after Salesforce creates the gateway order.

### 6.4 Boundary handling

The discount calculation must have deterministic rules around tier boundaries.

Recommended rule:

> The discount tier is determined when Salesforce creates the payment quote/Razorpay Order, and the quote has a short expiration window. An expired quote cannot be reused.

The exact quote expiry duration is **[VERIFY]**.

### 6.5 Partial payments

If partial payment is supported for B2B invoices, the business rule must define whether the discount applies to the amount being paid, the remaining balance, or only a full eligible settlement.

For the initial POC, prefer **full-balance payment through Pay Now** unless partial gateway payments are explicitly required. This keeps discount accounting and reconciliation simpler.

### 6.6 Accounting treatment

The discount must not simply disappear from Salesforce. The accounting treatment must be represented in QuickBooks correctly.

QuickBooks supports invoice discount lines and Payment transactions linked to invoices and credit memos. The exact accounting representation for the early-payment discount must be tested in the sandbox before finalizing the implementation. **[VERIFY]**

Recommended POC flow:

```text
Invoice gross amount
        ↓
Early-payment discount adjustment
        ↓
Net amount eligible for payment
        ↓
Razorpay captured payment
        ↓
QuickBooks accounting payment / adjustment
        ↓
Invoice balance = expected balance
```

Do not create a QuickBooks payment for the gross amount when Razorpay actually collected a discounted amount.

---

## 7. Razorpay payment integration

### 7.1 Selected gateway

**Razorpay** is the selected payment gateway for this POC.

Reasons:

- Familiar to the team.
- Test Mode supports simulated payments without moving real money.
- Server-side Orders API.
- Standard hosted Checkout.
- Payment signature verification.
- Webhook-based event notifications.
- Refund APIs for captured payments.
- Straightforward REST integration suitable for an Apex callout wrapper.

Razorpay's official documentation describes the server-side Orders API, Checkout, signature verification, payment-status verification and webhook processing. Test Mode is intended for simulated transactions. **[VERIFY current API version, onboarding requirements and enabled payment methods during implementation.]**

### 7.2 Integration location

**Razorpay integration is implemented in Salesforce, not directly in QuickBooks.**

```text
Experience Cloud LWC
       |
       | Pay Now
       v
Salesforce Apex
       |
       | Create Razorpay Order
       v
Razorpay
       |
       | Checkout
       v
Customer payment
       |
       v
Razorpay payment
       |
       +----> Salesforce verification/webhook
       |
       +----> QuickBooks Payment
```

QuickBooks remains the accounting system and does not become the payment gateway.

### 7.3 Salesforce components

Recommended components:

- `RazorpayApiClient.cls` — common HTTP wrapper for Razorpay calls.
- `RazorpayPaymentService.cls` — authorization, quote validation and payment business logic.
- `RazorpayWebhookService.cls` — webhook verification and event processing.
- `RazorpayPaymentJob.cls` — optional asynchronous processing where needed.
- `Razorpay_Payment__c` — transaction/audit object if required.
- `Payment_Gateway_Config__mdt` — non-secret configuration.
- Named Credential / External Credential — secure endpoint/secret handling.
- LWC payment component — launches hosted Razorpay Checkout using the server-created order ID.

Never put the Razorpay API secret in LWC JavaScript, Custom Metadata, Git, or any client-visible source.

### 7.4 Payment lifecycle

```text
1. Customer opens unpaid invoice
2. Salesforce reads current invoice balance
3. Salesforce calculates B2B discount if eligible
4. Salesforce creates Razorpay Order
5. Customer opens Razorpay Checkout
6. Customer completes payment
7. LWC receives payment response
8. Salesforce verifies signature
9. Razorpay webhook is received
10. Salesforce verifies webhook authenticity
11. Salesforce confirms captured status
12. Salesforce records gateway transaction
13. Salesforce creates QuickBooks Payment linked to invoice
14. Salesforce fetches QuickBooks invoice
15. Salesforce updates Order balance/payment status
16. User sees confirmed payment
```

### 7.5 Idempotency

Payment events can arrive more than once or out of order.

Use:

- unique Razorpay Order ID;
- unique Razorpay Payment ID;
- webhook event/reference ID where available;
- Salesforce payment-record uniqueness;
- QuickBooks payment lookup before creating another payment;
- stored processing status;
- safe retry of failed synchronization.

The system must never create two QuickBooks payments for one captured Razorpay Payment ID.

### 7.6 Webhook security

Webhook requests must be cryptographically verified before processing.

The payment integration must:

- validate Razorpay's webhook signature using the configured secret;
- reject malformed/unauthenticated requests;
- avoid trusting payment amount supplied only by the client;
- compare the gateway transaction against the Salesforce payment quote/order;
- process events idempotently;
- log references and failures without storing sensitive payment data.

### 7.7 Test Mode

Development must use Razorpay Test Mode keys only.

Test cases must cover:

- successful payment;
- failed payment;
- abandoned checkout;
- duplicate webhook;
- webhook arriving before the UI callback is processed;
- UI callback without webhook;
- payment amount mismatch;
- invalid signature;
- already-paid invoice;
- expired discount quote;
- QuickBooks synchronization failure after Razorpay capture.

---

## 8. QuickBooks payment synchronization

### 8.1 Responsibility split

| Operation | Salesforce | Razorpay | QuickBooks |
|---|---|---|---|
| Show Pay Now | Yes | No | No |
| Calculate B2B discount | Yes | No | Accounting result only |
| Create gateway order | Yes | Receives order | No |
| Collect online payment | Orchestrates | **Yes** | No |
| Verify gateway payment | **Yes** | Source of payment state | No |
| Accounting invoice | Displays/synchronizes | No | **Yes** |
| Accounting payment | Synchronizes | No | **Yes** |
| Cash refund for gateway payment | Orchestrates | **Yes** | Accounting reconciliation |
| Credit memo | Orchestrates | No | **Yes** |

### 8.2 Existing QuickBooks payment sync

The existing QuickBooks webhook/fetch/reconciliation design remains valid for payments made through QuickBooks or other supported accounting-side methods.

Razorpay becomes an additional payment source rather than replacing the existing QuickBooks synchronization.

### 8.3 Reconciliation

The system must reconcile:

```text
Salesforce Order
    ↕
QuickBooks Invoice
    ↕
QuickBooks Payment
    ↕
Razorpay Payment
```

A mismatch must be visible rather than silently corrected.

Examples:

- Razorpay captured but QBO payment missing → integration retry/alert.
- QBO payment exists but no Razorpay payment → investigate as external/manual payment.
- Razorpay amount differs from Salesforce quote → mark mismatch and do not automatically apply accounting payment.
- QBO invoice balance differs from expected balance → reconciliation flags drift.

---

## 9. Returns and customer-facing return feature

### 9.1 Return feature is end-user functionality

Returns are now a customer-facing portal feature. Authenticated B2B and B2C users can initiate eligible returns from the portal.

The existing `QboReturnRequestService` and `QboCreditMemoJob` remain the backend foundation.

The current **Returns** navigation item should become a working portal destination rather than a placeholder.

### 9.2 Return user journey

```text
My Orders
   ↓
Open Order
   ↓
Select Return
   ↓
Select item(s) + quantity
   ↓
Select reason
   ↓
Select eligible resolution
   ↓
Submit Return Request
   ↓
Requested
   ↓
Internal approval
   ├── Rejected → Rejected
   └── Approved
          ↓
      Processing
          ↓
   QBO credit/refund step machine
          ↓
      Credited / Refunded
```

### 9.3 Authorization

Before allowing a return request, Salesforce must verify server-side that:

- the order belongs to the user's authorized account context;
- the user is permitted to act for that account;
- the order is eligible for return;
- the selected OrderItems belong to that Order;
- the requested quantity does not exceed the remaining returnable quantity;
- the order has the required QuickBooks invoice reference;
- the requested resolution is permitted.

The browser must not be trusted to provide an arbitrary Order ID, OrderItem ID, account ID, or quantity.

### 9.4 Return quantity protection

The existing validation against `Returned_Quantity__c` remains required.

For concurrent return requests, the final implementation must prevent two requests from independently consuming the same remaining quantity. **[VERIFY implementation strategy]**

### 9.5 Return resolution types

The existing service supports:

- `Applied to Invoice`
- `Refunded`
- `Customer Credit`

The portal should show only resolution choices appropriate to the order/payment state and business policy.

### 9.6 Gateway-aware returns

The return processor must distinguish between:

**Unpaid invoice**  
→ QBO credit memo can reduce the outstanding balance according to the existing return logic.

**Partially paid invoice**  
→ QBO credit memo plus the appropriate payment/credit handling.

**Fully paid through QuickBooks**  
→ Existing QBO refund/credit path.

**Paid through Razorpay**  
→ initiate the Razorpay refund against the captured Razorpay payment, then reconcile the corresponding QuickBooks accounting entry and Salesforce return.

A Razorpay refund must never be issued simply because a Return Request was submitted. It happens only after approval and only when the financial step is reached.

### 9.7 Return idempotency

Every return step must be safe to retry.

Required guards:

- existing QBO Credit Memo ID;
- existing QBO Payment/Refund ID;
- existing Razorpay Refund ID;
- return step/status;
- integration log/reference;
- external lookup before creating a duplicate financial transaction.

### 9.8 User-facing return status

The portal should provide a clear status timeline:

```text
Return Requested
      ↓
Under Review
      ↓
Approved
      ↓
Processing
      ↓
Credit / Refund Completed
```

If the integration fails, show a useful non-technical status such as **Processing delayed** while retaining the technical error in the internal log.

---

## 10. Security model

### 10.1 Site model

Use one LWR Experience Cloud site.

### 10.2 Data access

The existing design remains:

- Account OWD = Private.
- Order visibility follows Account through Controlled by Parent where supported.
- Partners receive access to authorized customer Accounts.
- Portal users receive only the object/field permissions required for their role.
- LWC visibility is not the security boundary.

### 10.3 Apex

All portal-facing Apex must use appropriate sharing and explicit authorization checks.

For queries that intentionally use system mode, the service must perform its own authorization check before returning or modifying data.

### 10.4 Pricing security

Never accept these values as authoritative from the browser:

- pricebook ID;
- unit price;
- discount percent;
- discount amount;
- payable amount;
- account ID;
- Razorpay amount.

Salesforce calculates/validates them.

### 10.5 Payment security

- Secrets live in Named/External Credentials or the appropriate secure Salesforce credential mechanism.
- No Razorpay secret in source code.
- No payment-card credentials stored in Salesforce.
- Verify payment signatures server-side.
- Verify webhook signatures.
- Validate payment amount against the Salesforce payment quote.
- Use idempotency guards.
- Log references, not sensitive payment credentials.

---

## 11. Build phases

Each phase ends with a **checkpoint**. Do not proceed to the next phase until the checkpoint is reviewed and the relevant Salesforce tests pass.

### Phase 0 — Environment (about 1 day)

- Verify Salesforce Developer Edition, Experience Cloud, licences, storage and features.
- Verify Intuit Developer account, application and sandbox company.
- Verify Razorpay account/Test Mode availability.
- Set up VS Code + Salesforce CLI + Git.
- Confirm Named/External Credential strategy for QuickBooks and Razorpay.
- **Done when:** Salesforce, QuickBooks sandbox and Razorpay Test Mode can all be accessed with test credentials.
- **Checkpoint:** licence counts, QBO API call, Razorpay Test Mode access.

### Phase 1 — Data model and security foundation (2–3 days)

- Enable Orders.
- Confirm Account/persona model.
- Create/verify B2B and B2C pricebooks.
- Create/verify custom fields for B2B margin, discount and payment references.
- Create/verify return objects and integration logging.
- Create/verify payment transaction object if required.
- Set external OWDs to Private as required.
- Verify Order Controlled by Parent behaviour.
- Verify partner-to-customer Account access.
- **Done when:** the schema, security model and two pricebooks exist and a test user can be correctly classified.
- **Checkpoint:** object/field/relationship and sharing design.

### Phase 2 — Single-site B2B/B2C portal experience (4–6 days)

- Keep the existing LWR Experience Cloud site.
- Resolve authenticated user's B2B/B2C audience in Apex.
- Update portal shell to render audience-specific navigation/features.
- Upgrade catalog cards with audience-appropriate information.
- B2B: show business pricing, optional recommended retail price and indicative margin.
- B2C: hide B2B-only information.
- Configure B2B/B2C pricebooks through metadata.
- Ensure the order submission service uses the server-resolved pricebook.
- **Done when:** one site presents the correct experience and pricebook to each persona.
- **Checkpoint:** B2B/B2C UI and security matrix.

### Phase 3 — QuickBooks connectivity (2–3 days)

- Register the redirect URI.
- Configure Auth Provider, External Credential and Named Credential.
- Use `QboApiClient` as the common QuickBooks wrapper.
- Sync test customers/items and store QBO IDs.
- **Done when:** Apex can query a QBO customer and read an item.
- **Checkpoint:** `QboApiClient` and integration tests.

### Phase 4 — Async invoicing (4–5 days)

- Platform event, trigger, `QboInvoiceJob`, payload builder, log service.
- Implement duplicate guards and failure alerting.
- **Done when:** placing an order creates one matching invoice and retries do not duplicate it.
- **Checkpoint:** invoice job and duplicate-guard tests.

### Phase 5 — QuickBooks payment sync, overdue and reconciliation (4–5 days)

- Existing QuickBooks webhook receiver.
- Fetch job.
- Payment status mapping.
- Scheduled overdue calculation.
- Nightly reconciliation batch.
- **Done when:** QBO payment changes update Salesforce correctly and missed webhooks are recovered.
- **Checkpoint:** webhook security review and reconciliation tests.

### Phase 6 — End-user returns and credit memos (5–7 days)

- Expose Returns in the portal.
- Build return request UI.
- Secure order/line authorization.
- Validate remaining returnable quantity.
- Maintain internal approval.
- Keep the existing `QboCreditMemoJob` step machine.
- Cover unpaid, partially paid and fully paid invoices.
- Update returned quantities and line status.
- Display return status to the user.
- Add Razorpay-aware refund path where a Razorpay payment exists.
- **Done when:** users can submit eligible returns, approval is required, all supported financial paths complete exactly once, and retry does not duplicate financial transactions.
- **Checkpoint:** return step machine and end-user security test matrix.

### Phase 7 — B2B early-payment discount (3–5 days)

- Define final business discount percentages.
- Create `B2B_Early_Payment_Discount__mdt` or approved equivalent.
- Calculate eligibility from invoice issue date and current date.
- Keep existing QBO due date unchanged.
- Add B2B discount information to the portal.
- Build server-side payment quote calculation.
- Ensure discount cannot be altered by the browser.
- Determine and test QuickBooks accounting representation.
- **Done when:** B2B users see the correct current discount and the same amount is used for payment/accounting.
- **Checkpoint:** discount boundary tests and QBO accounting test.

### Phase 8 — Razorpay online payments (4–6 days)

- Create Razorpay Test Mode credentials.
- Configure Named/External Credential.
- Build `RazorpayApiClient`.
- Build payment-order creation service.
- Add Pay Now UI.
- Launch Razorpay Checkout.
- Verify payment signatures.
- Implement webhook receiver.
- Store payment references/status.
- Create QuickBooks Payment after verified capture.
- Refresh QBO invoice and Salesforce balance.
- Implement idempotency and failure recovery.
- **Done when:** a successful Razorpay test payment updates Salesforce and creates exactly one corresponding QBO payment.
- **Checkpoint:** complete payment test matrix.

### Phase 9 — Gateway-aware refunds and reconciliation (3–5 days)

- Determine whether the return is associated with a Razorpay payment.
- Create Razorpay refund only after approval and only for captured payments.
- Store Razorpay Refund ID.
- Synchronize accounting-side refund/credit treatment with QBO.
- Re-fetch QBO invoice balance.
- Update Salesforce return/order status.
- Handle refund failures and retries.
- **Done when:** a Razorpay-paid return can be refunded without duplicate gateway refunds or inconsistent accounting.
- **Checkpoint:** full/partial refund and retry matrix.

### Phase 10 — Hardening, reports and demo (3–4 days)

- Complete Apex tests with callout mocks.
- Complete security tests.
- Complete B2B/B2C pricing tests.
- Complete payment tests.
- Complete return tests.
- Build reports/dashboards.
- Implement/verify purge job.
- Update README.
- Create demo script.
- Document known limitations.
- **Done when:** the end-to-end demo is repeatable and the test/security matrix passes.
- **Checkpoint:** final POC review.

### Revised rough effort

Approximately **35–50 working days part-time**, depending on Razorpay onboarding, the QuickBooks discount-accounting experiment, and the amount of UI refinement required.

---

## 12. Test scenarios

### Security

1. Partner A cannot see Partner B's orders.
2. Partner A cannot see another partner's customer accounts unless explicitly shared.
3. Direct B2C customer cannot see partner orders.
4. B2C user cannot query B2B pricebook entries through Apex.
5. B2C user cannot see B2B margin information.
6. B2B user cannot submit an order for an unauthorized customer account.
7. User cannot create a return for an order belonging to another account.
8. User cannot submit a return line belonging to another order.

### Catalog and pricing

9. B2B user receives B2B pricebook.
10. B2C user receives B2C pricebook.
11. Same product can have different B2B and B2C prices.
12. Browser-supplied price is ignored.
13. Browser-supplied pricebook is ignored.
14. Inactive PricebookEntry is rejected.
15. Product unavailable to the audience is rejected.
16. B2B margin is calculated correctly.
17. B2B margin is not exposed to B2C.

### Ordering and invoicing

18. Double-click submit creates one Order.
19. Burst of scripted orders produces no duplicate invoices.
20. Invoice lines, quantities, prices and tax match the Order.
21. QBO 429/500 results in safe retry.
22. Bad/unmapped product produces visible failure.
23. Placed-by and for-whom information are preserved.

### Existing payment synchronization

24. Full QBO payment → `Paid`.
25. Partial QBO payment → `Partially Paid` with correct balance.
26. Past-due date → `Overdue` after the scheduled job.
27. Duplicate/out-of-order QBO webhook → correct final state.
28. Missed QBO webhook → nightly reconciliation corrects it and flags drift.

### Early-payment discount

29. Payment during days 1–7 receives the highest configured discount.
30. Payment after day 7 receives the next configured discount.
31. Payment after subsequent tiers receives the correct lower discount.
32. Payment after the due date receives no early-payment discount.
33. Discount calculation uses the server-side invoice date.
34. Browser cannot increase the discount.
35. Browser cannot reduce the payable amount independently.
36. Expired payment quote cannot be reused.
37. Discounted Razorpay amount matches the Salesforce payment quote.
38. QuickBooks accounting balance reconciles after the discounted payment.

### Razorpay payments

39. Successful Test Mode payment is captured.
40. Failed payment does not mark the Order as Paid.
41. Abandoned checkout does not create a successful payment.
42. Invalid signature is rejected.
43. Invalid webhook signature is rejected.
44. Duplicate webhook is harmless.
45. Out-of-order webhook does not corrupt the final state.
46. Razorpay Payment ID cannot create a second QBO payment.
47. Amount mismatch is rejected/flagged.
48. QBO payment failure after Razorpay capture is retried safely.
49. Reconciliation identifies Razorpay/QBO mismatch.

### Returns

50. Partial return on unpaid invoice works.
51. Return on partially paid invoice works.
52. Return on fully paid QBO invoice follows the refund/credit path.
53. Razorpay-paid order triggers the gateway refund path after approval.
54. Full Razorpay refund works.
55. Partial Razorpay refund works if enabled by the business rule.
56. Duplicate return processing creates no second credit memo.
57. Duplicate return processing creates no second Razorpay refund.
58. Returning more than remaining quantity is blocked.
59. Concurrent return attempts cannot over-return an OrderItem.
60. Rejection creates no financial transaction.
61. Failed financial step remains visible and retryable.
62. Return status shown to the user matches the verified backend state.

---

## 13. Reports and dashboards

### Order dashboard

- Orders by B2B/B2C audience.
- Order value by audience.
- Orders pending QBO invoice.
- Failed invoice syncs.
- Orders with payment outstanding.

### Payment dashboard

- Paid vs partially paid vs unpaid vs overdue.
- Razorpay payments by status.
- Razorpay-to-QBO reconciliation mismatches.
- Early-payment discounts granted.
- Estimated value of B2B early-payment incentives.

### Return dashboard

- Requested returns.
- Pending approval.
- Processing.
- Credited.
- Refunded.
- Failed returns.
- Return value by B2B/B2C audience.
- Gateway refunds pending reconciliation.

Do not expose internal integration errors to external users through reports.

---

## 14. Purge and data-retention strategy

Developer Edition storage is limited. Integration logs can consume storage quickly.

The purge strategy should:

- retain enough information to diagnose recent failures;
- remove old verbose request/response bodies;
- retain important external IDs and final status;
- avoid storing unnecessary payment-sensitive data;
- preserve important order/return audit fields independently of verbose integration logs.

The purge job must not delete active or unresolved failures.

---

## 15. Demo script

### B2C demo

1. Log in as a direct customer.
2. Show the B2C catalog and retail price.
3. Add products to cart.
4. Submit an order.
5. Show the order confirmation.
6. Show QBO invoice creation.
7. Click Pay Now.
8. Complete a Razorpay Test Mode payment.
9. Show payment status in Salesforce.
10. Show the corresponding QBO payment.
11. Open My Orders.
12. Submit a partial return.
13. Approve the return internally.
14. Show the return status and refund/credit result.

### B2B demo

1. Log in as a partner/business user.
2. Show the B2B catalog and different B2B pricebook price.
3. Show recommended retail price and indicative margin.
4. Place an order for an authorized customer.
5. Show invoice number and due date.
6. Show the early-payment discount available during the first seven days.
7. Click Pay Now.
8. Show the discounted payable amount.
9. Complete Razorpay Test Mode payment.
10. Show Salesforce payment status and QBO accounting payment.
11. Submit a return.
12. Approve the return internally.
13. Show the gateway refund/accounting reconciliation.
14. Log in as another partner and prove the first partner's data is not visible.

---

## 16. Implementation rules for the team

1. Work from the GitHub `develop` branch.
2. Inspect existing code before creating a new class/component/object.
3. Do not duplicate an existing service when an existing service can be safely extended.
4. Do not weaken tests merely to make deployment pass.
5. Every external callout must have a callout mock test.
6. Every payment/refund creation path must be idempotent.
7. Every portal-facing mutation must perform server-side authorization.
8. Never trust client-supplied price, discount, account, or payment amount.
9. Never commit secrets or live payment credentials.
10. Keep QuickBooks as the accounting system and Razorpay as the payment gateway.
11. Do not remove existing QuickBooks payment synchronization because Razorpay is being added.
12. Preserve the existing return approval requirement.
13. Preserve the existing return step-machine/idempotency design.
14. Deploy incrementally and run focused tests after each logical change.
15. Before changing architecture, update this guide and record the reason.

---

## 17. Decisions confirmed for the next implementation stage

| Decision | Status |
|---|---|
| One Experience Cloud site for B2B + B2C | **Confirmed** |
| Different B2B and B2C experiences | **Confirmed** |
| Separate B2B and B2C pricebooks | **Confirmed** |
| B2B business information such as indicative resale margin | **Confirmed** |
| B2B early-payment discount | **Confirmed** |
| Highest discount during first 7 days | **Confirmed** |
| Discount decreases as payment is delayed | **Confirmed** |
| Existing QBO payment due date remains | **Confirmed** |
| Exact discount percentages | **To be supplied/configured** |
| Customer-facing Returns | **Confirmed** |
| Internal approval before financial return processing | **Confirmed / existing design** |
| Razorpay as online payment gateway | **Confirmed** |
| Razorpay integration layer | **Salesforce** |
| QuickBooks role | **Accounting/invoicing/payment synchronization** |
| Razorpay role | **Online payment collection and gateway refunds** |
| Razorpay Test Mode for development | **Confirmed** |
| Razorpay live merchant onboarding | **Later / production step** |
| Gateway-aware refunds | **Required** |
| B2B/B2C single-site security | **Required** |

---

## 18. External reference notes

The B2B experience uses established commerce patterns such as company/business profiles, customer-specific catalogs and pricing, quantity rules, volume pricing, payment terms, reordering, and self-service returns. These patterns are consistent with current B2B commerce documentation and are used as design references only.

Salesforce Enhanced LWR supports expression-based component visibility. For this project, visibility should supplement—not replace—server-side Apex authorization.

Razorpay documentation describes the server-created Orders API, hosted Checkout, mandatory signature verification, captured-payment verification and webhook-driven event processing. Test Mode provides simulated payments without real-money movement. Refunds are supported for captured payments. **[VERIFY current API version, onboarding requirements, enabled payment methods and live commercial terms before production.]**

QuickBooks Online API documentation supports Payment transactions linked to Invoices and Credit Memos. Invoice transactions can contain discount lines. The exact accounting representation of the early-payment discount must be validated in the sandbox before production use.

---

## 19. Final end-to-end architecture

```text
                         ONE EXPERIENCE CLOUD SITE
                                  |
                    +-------------+-------------+
                    |                           |
                 B2B USER                    B2C USER
                    |                           |
          B2B catalog / pricebook       B2C catalog / pricebook
          margin / business info        retail experience
          payment terms                 simple checkout
          early-payment discount        payment
          customer ordering             returns
                    |                           |
                    +-------------+-------------+
                                  |
                              Salesforce
                                  |
             +--------------------+--------------------+
             |                    |                    |
          Ordering             Payment              Returns
             |                    |                    |
       OrderSubmission     RazorpayPayment      ReturnRequestService
             |                    |                    |
       Order + Items       Razorpay Order       Return Request
             |                    |                    |
             v                    v                    v
     Order Invoice Event     Razorpay Checkout   Approval Process
             |                    |                    |
             v                    v                    v
       QboInvoiceJob       Verified Payment      QboCreditMemoJob
             |                    |                    |
             +--------------------+--------------------+
                                  |
                           QuickBooks Online
                                  |
          Invoice / Payment / Credit Memo / Accounting Refund
                                  |
                         Webhook + Fetch + Reconcile
                                  |
                              Salesforce
                                  |
                         Portal status / audit
```

**Complete POC definition of done:** a B2B or B2C user can log into the same portal, receive the correct experience and pricebook, place an order, receive a QuickBooks invoice, see the applicable B2B early-payment incentive when eligible, pay online through Razorpay, have the verified payment reflected in Salesforce and QuickBooks, and submit an approved return that follows the correct credit/refund path without duplicate financial transactions.
