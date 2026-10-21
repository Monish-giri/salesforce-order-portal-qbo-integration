public with sharing class QboInvoiceJob implements Queueable, Database.AllowsCallouts {
    private static final String NAMED_CREDENTIAL = 'QuickBooks_Sandbox';
    private static final String INVOICE_PATH = '/v3/company/{realmId}/invoice';
    private static final String QUERY_PATH = '/v3/company/{realmId}/query';
    private final Id orderId;

    public QboInvoiceJob(Id orderId) {
        this.orderId = orderId;
    }

    public void execute(QueueableContext context) {
        if (orderId == null) {
            return;
        }

        Order order = [
            SELECT Id, OrderNumber, AccountId, EffectiveDate, Status,
                   QBO_Invoice_Id__c, Invoice_Status__c,
                   (SELECT Id, Quantity, UnitPrice, TotalPrice,
                           PricebookEntry.Product2.Name,
                           PricebookEntry.Product2.QBO_Item_Id__c
                    FROM OrderItems
                    ORDER BY CreatedDate ASC)
            FROM Order
            WHERE Id = :orderId
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        if (String.isNotBlank(order.QBO_Invoice_Id__c)) {
            return;
        }

        String requestId = 'INV-' + order.OrderNumber;
        String docNumber = 'SO-' + order.OrderNumber;
        String responseBody;

        try {
            QboCustomerService.CustomerResolution customerResolution =
                QboCustomerService.resolveCustomerForInvoice(order.AccountId);

            QBO_Config__mdt config = getConfig();
            InvoiceData invoiceData = findExistingInvoice(config, docNumber);

            if (invoiceData == null) {
                invoiceData = createInvoice(config, order, customerResolution.qboId, docNumber, requestId);
            }

            responseBody = invoiceData.rawBody;

            List<Order> orderUpdates = new List<Order>{
                new Order(
                    Id = order.Id,
                    QBO_Invoice_Id__c = invoiceData.id,
                    QBO_Invoice_Number__c = invoiceData.docNumber,
                    Invoice_Issue_Date__c = invoiceData.invoiceDate,
                    Invoice_Total__c = invoiceData.totalAmount,
                    Invoice_Balance__c = invoiceData.balance,
                    Invoice_Due_Date__c = invoiceData.dueDate,
                    Invoice_Status__c = 'Invoiced',
                    Last_QBO_Sync__c = System.now(),
                    Payment_Status__c = derivePaymentStatus(invoiceData.totalAmount, invoiceData.balance, invoiceData.dueDate)
                )
            };

            Database.update(orderUpdates, AccessLevel.SYSTEM_MODE);
            QboCustomerService.persistCustomerResolution(customerResolution);

            insert new QBO_Sync_Log__c(
                Direction__c = 'Outbound',
                Object_Type__c = 'Invoice',
                Operation__c = 'Create/Ensure',
                Related_Record_Id__c = String.valueOf(order.Id),
                Request_Id__c = requestId,
                Status__c = 'Success',
                HTTP_Status__c = invoiceData.httpStatus,
                Response_Snippet__c = truncate(responseBody, 1000)
            );
        } catch (Exception ex) {
            Database.update(new Order(
                Id = order.Id,
                Invoice_Status__c = 'Failed',
                Last_QBO_Sync__c = System.now()
            ), AccessLevel.SYSTEM_MODE);

            insert new QBO_Sync_Log__c(
                Direction__c = 'Outbound',
                Object_Type__c = 'Invoice',
                Operation__c = 'Create/Ensure',
                Related_Record_Id__c = String.valueOf(order.Id),
                Request_Id__c = requestId,
                Status__c = 'Failed',
                Error_Message__c = truncate(ex.getMessage(), 255),
                Response_Snippet__c = truncate(responseBody, 1000)
            );
        }
    }

    private class InvoiceData {
        String id;
        String docNumber;
        String syncToken;
        Date invoiceDate;
        Decimal totalAmount;
        Decimal balance;
        Date dueDate;
        Integer httpStatus;
        String rawBody;
    }

    private static QBO_Config__mdt getConfig() {
        QBO_Config__mdt config = QBO_Config__mdt.getInstance('Default');
        if (config == null || String.isBlank(config.Realm_Id__c)) {
            throw new QboInvoiceException('QBO_Config__mdt Default record is missing Realm_Id__c.');
        }
        if (String.isBlank(config.Minor_Version__c)) {
            throw new QboInvoiceException('QBO_Config__mdt Default record is missing Minor_Version__c.');
        }
        return config;
    }

    private static InvoiceData findExistingInvoice(QBO_Config__mdt config, String docNumber) {
        String query = 'select Id, DocNumber, SyncToken, TxnDate, TotalAmt, Balance, DueDate from Invoice where DocNumber = \''
            + String.escapeSingleQuotes(docNumber)
            + '\' maxresults 1';

        HttpRequest request = new HttpRequest();
        request.setEndpoint(buildQueryEndpoint(config, query));
        request.setMethod('GET');
        request.setHeader('Accept', 'application/json');
        request.setTimeout(20000);

        HttpResponse response = new Http().send(request);
        assertSuccess(response, 'QBO invoice lookup');

        Map<String, Object> payload = parseObject(response.getBody());
        Map<String, Object> queryResponse = (Map<String, Object>) payload.get('QueryResponse');
        if (queryResponse == null || !queryResponse.containsKey('Invoice')) {
            return null;
        }

        List<Object> invoices = (List<Object>) queryResponse.get('Invoice');
        if (invoices == null || invoices.isEmpty()) {
            return null;
        }

        Map<String, Object> invoice = (Map<String, Object>) invoices[0];
        return toInvoiceData(invoice, response.getStatusCode(), response.getBody());
    }

    private static InvoiceData createInvoice(
        QBO_Config__mdt config,
        Order order,
        String qboCustomerId,
        String docNumber,
        String requestId
    ) {
        if (String.isBlank(qboCustomerId)) {
            throw new QboInvoiceException('QBO Customer Id is required before invoice creation.');
        }
        if (order.OrderItems.isEmpty()) {
            throw new QboInvoiceException('Order has no OrderItems.');
        }

        List<Object> lines = new List<Object>();
        for (OrderItem item : order.OrderItems) {
            String qboItemId = item.PricebookEntry.Product2.QBO_Item_Id__c;
            if (String.isBlank(qboItemId)) {
                throw new QboInvoiceException(
                    'Product ' + item.PricebookEntry.Product2.Name + ' has no QBO_Item_Id__c.'
                );
            }

            Decimal quantity = item.Quantity;
            Decimal unitPrice = item.UnitPrice;
            Decimal amount = quantity * unitPrice;

            lines.add(new Map<String, Object>{
                'DetailType' => 'SalesItemLineDetail',
                'Amount' => amount,
                'Description' => item.PricebookEntry.Product2.Name,
                'SalesItemLineDetail' => new Map<String, Object>{
                    'ItemRef' => new Map<String, Object>{ 'value' => qboItemId },
                    'Qty' => quantity,
                    'UnitPrice' => unitPrice
                }
            });
        }

        Map<String, Object> payload = new Map<String, Object>{
            'CustomerRef' => new Map<String, Object>{ 'value' => qboCustomerId },
            'DocNumber' => docNumber,
            'TxnDate' => String.valueOf(order.EffectiveDate),
            'PrivateNote' => 'SF Order ' + order.Id,
            'CustomerMemo' => new Map<String, Object>{ 'value' => 'Order ' + order.OrderNumber },
            'Line' => lines
        };

        HttpRequest request = new HttpRequest();
        request.setEndpoint(
            'callout:' + NAMED_CREDENTIAL
            + INVOICE_PATH.replace(
                '{realmId}',
                EncodingUtil.urlEncode(config.Realm_Id__c.trim(), 'UTF-8')
            )
            + '?minorversion=' + EncodingUtil.urlEncode(config.Minor_Version__c.trim(), 'UTF-8')
            + '&requestid=' + EncodingUtil.urlEncode(requestId, 'UTF-8')
        );
        request.setMethod('POST');
        request.setHeader('Accept', 'application/json');
        request.setHeader('Content-Type', 'application/json');
        request.setTimeout(20000);
        request.setBody(JSON.serialize(payload));

        HttpResponse response = new Http().send(request);
        assertSuccess(response, 'QBO invoice creation');

        Map<String, Object> payloadResponse = parseObject(response.getBody());
        Map<String, Object> invoice = (Map<String, Object>) payloadResponse.get('Invoice');
        if (invoice == null || !invoice.containsKey('Id')) {
            throw new QboInvoiceException('QBO invoice creation succeeded but returned no Invoice Id.');
        }

        return toInvoiceData(invoice, response.getStatusCode(), response.getBody());
    }

    private static String buildQueryEndpoint(QBO_Config__mdt config, String query) {
        return 'callout:' + NAMED_CREDENTIAL
            + QUERY_PATH.replace(
                '{realmId}',
                EncodingUtil.urlEncode(config.Realm_Id__c.trim(), 'UTF-8')
            )
            + '?minorversion=' + EncodingUtil.urlEncode(config.Minor_Version__c.trim(), 'UTF-8')
            + '&query=' + EncodingUtil.urlEncode(query, 'UTF-8');
    }

    private static InvoiceData toInvoiceData(
        Map<String, Object> invoice,
        Integer httpStatus,
        String rawBody
    ) {
        InvoiceData data = new InvoiceData();
        data.id = invoice.containsKey('Id') ? String.valueOf(invoice.get('Id')) : null;
        data.docNumber = invoice.containsKey('DocNumber') ? String.valueOf(invoice.get('DocNumber')) : null;
        data.syncToken = invoice.containsKey('SyncToken') ? String.valueOf(invoice.get('SyncToken')) : null;
        data.invoiceDate = dateValue(invoice.get('TxnDate'));
        data.totalAmount = decimalValue(invoice.get('TotalAmt'));
        data.balance = decimalValue(invoice.get('Balance'));
        data.dueDate = dateValue(invoice.get('DueDate'));
        data.httpStatus = httpStatus;
        data.rawBody = rawBody;

        if (String.isBlank(data.id)) {
            throw new QboInvoiceException('QBO invoice response contained no Id.');
        }
        return data;
    }

    private static Decimal decimalValue(Object value) {
        return value == null ? null : Decimal.valueOf(String.valueOf(value));
    }

    private static Date dateValue(Object value) {
        if (value == null || String.isBlank(String.valueOf(value))) {
            return null;
        }
        return Date.valueOf(String.valueOf(value).substring(0, 10));
    }

    private static String derivePaymentStatus(Decimal totalAmount, Decimal balance, Date dueDate) {
        if (totalAmount == null || balance == null) {
            return null;
        }
        if (balance == 0) {
            return 'Paid';
        }
        if (balance > 0 && balance < totalAmount) {
            return 'Partially Paid';
        }
        if (balance == totalAmount) {
            return (dueDate != null && dueDate < Date.today()) ? 'Overdue' : 'Unpaid';
        }
        return 'Unpaid';
    }

    private static Map<String, Object> parseObject(String body) {
        if (String.isBlank(body)) {
            throw new QboInvoiceException('QBO returned an empty response.');
        }
        try {
            return (Map<String, Object>) JSON.deserializeUntyped(body);
        } catch (Exception ex) {
            throw new QboInvoiceException('QBO returned invalid JSON.');
        }
    }

    private static void assertSuccess(HttpResponse response, String operation) {
        Integer statusCode = response.getStatusCode();
        if (statusCode < 200 || statusCode >= 300) {
            throw new QboInvoiceException(
                operation + ' failed (' + statusCode + '): ' + response.getBody()
            );
        }
    }

    private static String truncate(String value, Integer maxLength) {
        if (String.isBlank(value)) {
            return null;
        }
        return value.length() <= maxLength ? value : value.substring(0, maxLength);
    }

    public class QboInvoiceException extends Exception {}
}
