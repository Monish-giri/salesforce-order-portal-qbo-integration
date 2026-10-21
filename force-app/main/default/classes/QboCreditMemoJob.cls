public with sharing class QboCreditMemoJob implements Queueable, Database.AllowsCallouts {
    private static final String NAMED_CREDENTIAL = 'QuickBooks_Sandbox';
    private static final String ENTITY_PATH = '/v3/company/{realmId}/';
    private final Id returnRequestId;

    public QboCreditMemoJob(Id returnRequestId) {
        this.returnRequestId = returnRequestId;
    }

    public void execute(QueueableContext context) {
        if (returnRequestId == null) return;
        Return_Request__c request = [
            SELECT Id, Name, Order__c, Status__c, Current_Step__c, Resolution_Type__c,
                   QBO_CreditMemo_Id__c, QBO_Payment_Id__c, QBO_Refund_Id__c,
                   Order__r.OrderNumber, Order__r.QBO_Invoice_Id__c,
                   Order__r.Account.QBO_Customer_Id__c,
                   (SELECT Id, Quantity__c, Unit_Price__c, Line_Amount__c, Order_Item__c,
                           Order_Item__r.PricebookEntry.Product2.Name,
                           Order_Item__r.PricebookEntry.Product2.QBO_Item_Id__c
                    FROM Return_Request_Lines__r ORDER BY CreatedDate ASC)
            FROM Return_Request__c WHERE Id = :returnRequestId WITH SYSTEM_MODE LIMIT 1
        ];
        if (request.Status__c != 'Approved' && request.Status__c != 'Processing') return;

        try {
            QBO_Config__mdt config = getConfig();
            String customerId = request.Order__r.Account.QBO_Customer_Id__c;
            String invoiceId = request.Order__r.QBO_Invoice_Id__c;
            if (String.isBlank(customerId) || String.isBlank(invoiceId)) {
                throw new QboCreditMemoException('Order must have QBO Customer Id and QBO Invoice Id.');
            }
            if (request.Return_Request_Lines__r.isEmpty()) {
                throw new QboCreditMemoException('Return Request has no lines.');
            }

            Decimal creditAmount = 0;
            List<Object> lines = new List<Object>();
            for (Return_Request_Line__c line : request.Return_Request_Lines__r) {
                Decimal amount = line.Line_Amount__c == null
                    ? line.Quantity__c * line.Unit_Price__c
                    : line.Line_Amount__c;
                if (amount <= 0) throw new QboCreditMemoException('Return line amount must be greater than zero.');
                String itemId = line.Order_Item__r.PricebookEntry.Product2.QBO_Item_Id__c;
                if (String.isBlank(itemId)) {
                    throw new QboCreditMemoException('Product ' + line.Order_Item__r.PricebookEntry.Product2.Name + ' has no QBO_Item_Id__c.');
                }
                creditAmount += amount;
                lines.add(new Map<String,Object>{
                    'DetailType' => 'SalesItemLineDetail',
                    'Amount' => amount,
                    'Description' => 'Return for Order ' + request.Order__r.OrderNumber,
                    'SalesItemLineDetail' => new Map<String,Object>{
                        'ItemRef' => new Map<String,Object>{'value' => itemId},
                        'Qty' => line.Quantity__c,
                        'UnitPrice' => line.Unit_Price__c
                    }
                });
            }

            String creditMemoId = request.QBO_CreditMemo_Id__c;
            if (String.isBlank(creditMemoId)) {
                creditMemoId = findExistingCreditMemo(config, request.Name);
            }
            if (String.isBlank(creditMemoId)) {
                creditMemoId = createCreditMemo(config, customerId, request.Name, lines);
            }

            String paymentId = request.QBO_Payment_Id__c;
            String refundId = request.QBO_Refund_Id__c;
            String finalStatus;
            InvoiceState refreshedInvoice;

            if (request.Resolution_Type__c == 'Customer Credit') {
                finalStatus = 'Credited';
            } else {
                InvoiceState invoice = readInvoice(config, invoiceId);
                Decimal balance = invoice.balance == null ? 0 : invoice.balance;
                if (balance > 0) {
                    Decimal applyAmount = Math.min(creditAmount, balance);
                    if (String.isBlank(paymentId)) {
                        paymentId = applyCredit(config, customerId, invoiceId, creditMemoId, applyAmount, request.Name);
                    }
                    finalStatus = 'Credited';
                } else if (request.Resolution_Type__c == 'Refunded') {
                    if (String.isBlank(refundId)) {
                        refundId = createRefundReceipt(config, customerId, creditMemoId, creditAmount, request.Name);
                    }
                    finalStatus = 'Refunded';
                } else {
                    throw new QboCreditMemoException('A fully paid invoice requires Refunded or Customer Credit resolution.');
                }
            }

            // All QBO callouts must complete before any DML in this transaction.
            refreshedInvoice = readInvoice(config, invoiceId);

            Return_Request__c requestUpdate = new Return_Request__c(
                Id = request.Id,
                Status__c = finalStatus,
                Current_Step__c = 'Done'
            );
            if (request.QBO_CreditMemo_Id__c != creditMemoId) {
                requestUpdate.QBO_CreditMemo_Id__c = creditMemoId;
            }
            if (request.QBO_Payment_Id__c != paymentId) {
                requestUpdate.QBO_Payment_Id__c = paymentId;
            }
            if (request.QBO_Refund_Id__c != refundId) {
                requestUpdate.QBO_Refund_Id__c = refundId;
            }
            update requestUpdate;

            Database.update(new Order(
                Id = request.Order__c,
                Invoice_Total__c = refreshedInvoice.total,
                Invoice_Balance__c = refreshedInvoice.balance,
                Invoice_Due_Date__c = refreshedInvoice.dueDate,
                Payment_Status__c = derivePaymentStatus(refreshedInvoice.total, refreshedInvoice.balance, refreshedInvoice.dueDate),
                Last_QBO_Sync__c = System.now()
            ), AccessLevel.SYSTEM_MODE);
        } catch (Exception ex) {
            update new Return_Request__c(Id = request.Id, Status__c = 'Failed');
            insert new QBO_Sync_Log__c(
                Direction__c = 'Outbound', Object_Type__c = 'CreditMemo',
                Operation__c = 'Return Processing', Related_Record_Id__c = String.valueOf(request.Id),
                Request_Id__c = 'CM-' + request.Name, Status__c = 'Failed',
                Error_Message__c = truncate(ex.getMessage(), 255)
            );
        }
    }

    private static String findExistingCreditMemo(QBO_Config__mdt config, String returnName) {
        String query = 'select Id from CreditMemo where DocNumber = \'CM-' + String.escapeSingleQuotes(returnName) + '\' maxresults 1';
        HttpResponse response = send(config, 'GET', 'query', null, query, null);
        assertSuccess(response, 'QBO credit memo lookup');
        Map<String,Object> payload = parseObject(response.getBody());
        Map<String,Object> qr = (Map<String,Object>)payload.get('QueryResponse');
        if (qr == null || !qr.containsKey('CreditMemo')) return null;
        List<Object> memos = (List<Object>)qr.get('CreditMemo');
        if (memos == null || memos.isEmpty()) return null;
        return String.valueOf(((Map<String,Object>)memos[0]).get('Id'));
    }

    private static String createCreditMemo(QBO_Config__mdt config, String customerId, String returnName, List<Object> lines) {
        Map<String,Object> payload = new Map<String,Object>{
            'CustomerRef' => new Map<String,Object>{'value' => customerId},
            'DocNumber' => 'CM-' + returnName,
            'PrivateNote' => 'Salesforce Return Request ' + returnName,
            'Line' => lines
        };
        HttpResponse response = send(config, 'POST', 'creditmemo', JSON.serialize(payload), null, 'CM-' + returnName);
        assertSuccess(response, 'QBO credit memo creation');
        Map<String,Object> body = parseObject(response.getBody());
        Map<String,Object> memo = (Map<String,Object>)body.get('CreditMemo');
        String id = memo == null ? null : String.valueOf(memo.get('Id'));
        if (String.isBlank(id)) throw new QboCreditMemoException('QBO credit memo creation returned no Id.');
        return id;
    }

    private static String applyCredit(QBO_Config__mdt config, String customerId, String invoiceId, String creditMemoId, Decimal amount, String returnName) {
        Map<String,Object> payload = new Map<String,Object>{
            'CustomerRef' => new Map<String,Object>{'value' => customerId},
            'TotalAmt' => 0,
            'PrivateNote' => 'Apply ' + returnName,
            'Line' => new List<Object>{
                new Map<String,Object>{'Amount' => amount, 'LinkedTxn' => new List<Object>{new Map<String,Object>{'TxnId' => invoiceId, 'TxnType' => 'Invoice'}}},
                new Map<String,Object>{'Amount' => amount, 'LinkedTxn' => new List<Object>{new Map<String,Object>{'TxnId' => creditMemoId, 'TxnType' => 'CreditMemo'}}}
            }
        };
        HttpResponse response = send(config, 'POST', 'payment', JSON.serialize(payload), null, 'RET-PAY-' + returnName);
        assertSuccess(response, 'QBO credit application');
        Map<String,Object> body = parseObject(response.getBody());
        Map<String,Object> payment = (Map<String,Object>)body.get('Payment');
        String id = payment == null ? null : String.valueOf(payment.get('Id'));
        if (String.isBlank(id)) throw new QboCreditMemoException('QBO credit application returned no Payment Id.');
        return id;
    }

    private static String createRefundReceipt(QBO_Config__mdt config, String customerId, String creditMemoId, Decimal amount, String returnName) {
        Map<String,Object> payload = new Map<String,Object>{
            'CustomerRef' => new Map<String,Object>{'value' => customerId},
            'TotalAmt' => amount,
            'PrivateNote' => 'Refund for ' + returnName,
            'Line' => new List<Object>{new Map<String,Object>{
                'Amount' => amount,
                'LinkedTxn' => new List<Object>{new Map<String,Object>{'TxnId' => creditMemoId, 'TxnType' => 'CreditMemo'}}
            }}
        };
        HttpResponse response = send(config, 'POST', 'refundreceipt', JSON.serialize(payload), null, 'RET-REF-' + returnName);
        assertSuccess(response, 'QBO refund receipt creation');
        Map<String,Object> body = parseObject(response.getBody());
        Map<String,Object> refund = (Map<String,Object>)body.get('RefundReceipt');
        String id = refund == null ? null : String.valueOf(refund.get('Id'));
        if (String.isBlank(id)) throw new QboCreditMemoException('QBO refund receipt creation returned no Id.');
        return id;
    }

    private class InvoiceState { Decimal total; Decimal balance; Date dueDate; }

    private static InvoiceState readInvoice(QBO_Config__mdt config, String invoiceId) {
        HttpResponse response = send(config, 'GET', 'invoice/' + EncodingUtil.urlEncode(invoiceId, 'UTF-8'), null, null, null);
        assertSuccess(response, 'QBO invoice read');
        Map<String,Object> body = parseObject(response.getBody());
        Map<String,Object> invoice = (Map<String,Object>)body.get('Invoice');
        if (invoice == null) throw new QboCreditMemoException('QBO invoice response contained no Invoice.');
        InvoiceState state = new InvoiceState();
        state.total = decimalValue(invoice.get('TotalAmt'));
        state.balance = decimalValue(invoice.get('Balance'));
        state.dueDate = dateValue(invoice.get('DueDate'));
        return state;
    }

    private static HttpResponse send(QBO_Config__mdt config, String method, String resource, String body, String query, String requestId) {
        String endpoint = 'callout:' + NAMED_CREDENTIAL + ENTITY_PATH.replace('{realmId}', EncodingUtil.urlEncode(config.Realm_Id__c.trim(), 'UTF-8')) + resource + '?minorversion=' + EncodingUtil.urlEncode(config.Minor_Version__c.trim(), 'UTF-8');
        if (query != null) endpoint += '&query=' + EncodingUtil.urlEncode(query, 'UTF-8');
        if (requestId != null) endpoint += '&requestid=' + EncodingUtil.urlEncode(requestId, 'UTF-8');
        HttpRequest request = new HttpRequest();
        request.setEndpoint(endpoint); request.setMethod(method); request.setHeader('Accept', 'application/json'); request.setTimeout(20000);
        if (body != null) { request.setHeader('Content-Type', 'application/json'); request.setBody(body); }
        return new Http().send(request);
    }

    private static QBO_Config__mdt getConfig() {
        QBO_Config__mdt config = QBO_Config__mdt.getInstance('Default');
        if (config == null || String.isBlank(config.Realm_Id__c)) throw new QboCreditMemoException('QBO_Config__mdt Default record is missing Realm_Id__c.');
        if (String.isBlank(config.Minor_Version__c)) throw new QboCreditMemoException('QBO_Config__mdt Default record is missing Minor_Version__c.');
        return config;
    }

    private static void assertSuccess(HttpResponse response, String operation) {
        if (response.getStatusCode() < 200 || response.getStatusCode() >= 300) throw new QboCreditMemoException(operation + ' failed (' + response.getStatusCode() + '): ' + response.getBody());
    }
    private static Map<String,Object> parseObject(String body) {
        if (String.isBlank(body)) throw new QboCreditMemoException('QBO returned an empty response.');
        try { return (Map<String,Object>)JSON.deserializeUntyped(body); } catch (Exception ex) { throw new QboCreditMemoException('QBO returned invalid JSON.'); }
    }
    private static Decimal decimalValue(Object value) { return value == null ? null : Decimal.valueOf(String.valueOf(value)); }
    private static Date dateValue(Object value) { return value == null || String.isBlank(String.valueOf(value)) ? null : Date.valueOf(String.valueOf(value).substring(0,10)); }
    private static String truncate(String value, Integer maxLength) { return String.isBlank(value) ? null : (value.length() <= maxLength ? value : value.substring(0,maxLength)); }
    private static String derivePaymentStatus(Decimal total, Decimal balance, Date dueDate) {
        if (total == null || balance == null) return null;
        if (balance == 0) return 'Paid';
        if (balance > 0 && balance < total) return 'Partially Paid';
        if (balance == total) return (dueDate != null && dueDate < Date.today()) ? 'Overdue' : 'Unpaid';
        return 'Unpaid';
    }
    public class QboCreditMemoException extends Exception {}
}
