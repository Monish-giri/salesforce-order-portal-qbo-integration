public with sharing class QboPaymentSyncJob implements Queueable, Database.AllowsCallouts {
private static final String NAMED_CREDENTIAL = 'QuickBooks_Sandbox';
private static final String INVOICE_PATH = '/v3/company/{realmId}/invoice/';
private static final String ENTITY_PATH = '/v3/company/{realmId}/';

private final String entityName;
private final String entityId;

public QboPaymentSyncJob(String entityName, String entityId) {
    this.entityName = entityName;
    this.entityId = entityId;
}

public void execute(QueueableContext context) {
    if (String.isBlank(entityName) || String.isBlank(entityId)) {
        return;
    }

    try {
        QBO_Config__mdt config = getConfig();
        Set<String> invoiceIds = new Set<String>();

        if (entityName == 'Invoice') {
            invoiceIds.add(entityId);
        } else if (entityName == 'Payment' || entityName == 'CreditMemo' || entityName == 'RefundReceipt') {
            invoiceIds.addAll(findLinkedInvoiceIds(config, entityName, entityId));
        }

        for (String invoiceId : invoiceIds) {
            refreshInvoice(config, invoiceId);
        }

        insert new QBO_Sync_Log__c(
            Direction__c = 'Inbound',
            Object_Type__c = entityName,
            Operation__c = 'Webhook Refresh',
            Related_Record_Id__c = invoiceIds.isEmpty() ? null : String.join(new List<String>(invoiceIds), ','),
            Request_Id__c = 'WEBHOOK-' + entityName + '-' + entityId,
            Status__c = 'Success'
        );
    } catch (Exception ex) {
        insert new QBO_Sync_Log__c(
            Direction__c = 'Inbound',
            Object_Type__c = entityName,
            Operation__c = 'Webhook Refresh',
            Request_Id__c = 'WEBHOOK-' + entityName + '-' + entityId,
            Status__c = 'Failed',
            Error_Message__c = truncate(ex.getMessage(), 255)
        );
    }
}

private static Set<String> findLinkedInvoiceIds(
QBO_Config__mdt config,
String entityName,
String entityId
) {
Set<String> invoiceIds = new Set<String>();

String safeEntityId = entityId.replace('\\', '\\\\').replace('\'', '\\\'');
String query = 'SELECT * FROM ' + entityName + ' WHERE Id = \'' + safeEntityId + '\'';

HttpRequest request = new HttpRequest();
request.setEndpoint(
    'callout:' + NAMED_CREDENTIAL
    + '/v3/company/'
    + EncodingUtil.urlEncode(config.Realm_Id__c.trim(), 'UTF-8')
    + '/query?query='
    + EncodingUtil.urlEncode(query, 'UTF-8')
    + '&minorversion='
    + EncodingUtil.urlEncode(config.Minor_Version__c.trim(), 'UTF-8')
);
request.setMethod('GET');
request.setHeader('Accept', 'application/json');
request.setTimeout(20000);

HttpResponse response = new Http().send(request);
assertSuccess(response, 'QBO ' + entityName + ' query');

Map<String, Object> payload = parseObject(response.getBody());

Map<String, Object> queryResponse =
    (Map<String, Object>) payload.get('QueryResponse');

if (queryResponse == null) {
    return invoiceIds;
}

Object recordsValue = queryResponse.get(entityName);

if (!(recordsValue instanceof List<Object>)) {
    return invoiceIds;
}

List<Object> records = (List<Object>) recordsValue;

for (Object recordValue : records) {
    if (!(recordValue instanceof Map<String, Object>)) {
        continue;
    }

    Map<String, Object> record =
        (Map<String, Object>) recordValue;

    collectLinkedInvoiceIds(record, invoiceIds);
}

return invoiceIds;
}

private static void collectLinkedInvoiceIds(
    Map<String, Object> record,
    Set<String> invoiceIds
) {
    Object lineValue = record.get('Line');

    if (lineValue instanceof List<Object>) {
        for (Object lineValueItem : (List<Object>) lineValue) {
            if (!(lineValueItem instanceof Map<String, Object>)) {
                continue;
            }

            Map<String, Object> line =
                (Map<String, Object>) lineValueItem;

            Object linkedValue = line.get('LinkedTxn');

            if (!(linkedValue instanceof List<Object>)) {
                continue;
            }

            for (Object linkedValueItem : (List<Object>) linkedValue) {
                if (!(linkedValueItem instanceof Map<String, Object>)) {
                    continue;
                }

                Map<String, Object> linkedTxn =
                    (Map<String, Object>) linkedValueItem;

                if (
                    String.valueOf(linkedTxn.get('TxnType')) == 'Invoice'
                    && linkedTxn.get('TxnId') != null
                ) {
                    invoiceIds.add(
                        String.valueOf(linkedTxn.get('TxnId'))
                    );
                }
            }
        }
    }

    Object lineExValue = record.get('LineEx');

    if (!(lineExValue instanceof Map<String, Object>)) {
        return;
    }

    Map<String, Object> lineEx =
        (Map<String, Object>) lineExValue;

    Object anyValue = lineEx.get('any');

    if (!(anyValue instanceof List<Object>)) {
        return;
    }

    for (Object anyItem : (List<Object>) anyValue) {
        if (!(anyItem instanceof Map<String, Object>)) {
            continue;
        }

        Map<String, Object> anyEntry =
            (Map<String, Object>) anyItem;

        Object valueObject = anyEntry.get('value');

        if (!(valueObject instanceof Map<String, Object>)) {
            continue;
        }

        Map<String, Object> nameValue =
            (Map<String, Object>) valueObject;

        if (
            String.valueOf(nameValue.get('Name')) == 'txnId'
            && nameValue.get('Value') != null
        ) {
            invoiceIds.add(
                String.valueOf(nameValue.get('Value'))
            );
        }
    }
}

private static void refreshInvoice(QBO_Config__mdt config, String invoiceId) {
    HttpRequest request = new HttpRequest();
    request.setEndpoint(
        'callout:' + NAMED_CREDENTIAL
        + INVOICE_PATH.replace(
            '{realmId}',
            EncodingUtil.urlEncode(config.Realm_Id__c.trim(), 'UTF-8')
        )
        + EncodingUtil.urlEncode(invoiceId, 'UTF-8')
        + '?minorversion='
        + EncodingUtil.urlEncode(config.Minor_Version__c.trim(), 'UTF-8')
    );
    request.setMethod('GET');
    request.setHeader('Accept', 'application/json');
    request.setTimeout(20000);

    HttpResponse response = new Http().send(request);
    assertSuccess(response, 'QBO invoice refresh');

    Map<String, Object> payload = parseObject(response.getBody());
    Map<String, Object> invoice = (Map<String, Object>) payload.get('Invoice');
    if (invoice == null) {
        throw new QboPaymentSyncException('QBO invoice response contained no Invoice.');
    }

    String qboId = stringValue(invoice.get('Id'));
    Decimal totalAmount = decimalValue(invoice.get('TotalAmt'));
    Decimal balance = decimalValue(invoice.get('Balance'));
    Date dueDate = dateValue(invoice.get('DueDate'));

    if (String.isBlank(qboId)) {
        throw new QboPaymentSyncException('QBO invoice response contained no Id.');
    }

    List<Order> orders = [
        SELECT Id
        FROM Order
        WHERE QBO_Invoice_Id__c = :qboId
        WITH SYSTEM_MODE
        LIMIT 1
    ];

    if (orders.isEmpty()) {
        return;
    }

    Database.update(new Order(
        Id = orders[0].Id,
        Invoice_Total__c = totalAmount,
        Invoice_Balance__c = balance,
        Invoice_Due_Date__c = dueDate,
        Payment_Status__c = derivePaymentStatus(totalAmount, balance, dueDate),
        Last_QBO_Sync__c = System.now()
    ), AccessLevel.SYSTEM_MODE);
}

private static QBO_Config__mdt getConfig() {
    QBO_Config__mdt config = QBO_Config__mdt.getInstance('Default');
    if (config == null || String.isBlank(config.Realm_Id__c)) {
        throw new QboPaymentSyncException('QBO_Config__mdt Default record is missing Realm_Id__c.');
    }
    if (String.isBlank(config.Minor_Version__c)) {
        throw new QboPaymentSyncException('QBO_Config__mdt Default record is missing Minor_Version__c.');
    }
    return config;
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
        throw new QboPaymentSyncException('QBO returned an empty response.');
    }
    try {
        return (Map<String, Object>) JSON.deserializeUntyped(body);
    } catch (Exception ex) {
        throw new QboPaymentSyncException('QBO returned invalid JSON.');
    }
}

private static void assertSuccess(HttpResponse response, String operation) {
    Integer statusCode = response.getStatusCode();
    if (statusCode < 200 || statusCode >= 300) {
        throw new QboPaymentSyncException(
            operation + ' failed (' + statusCode + '): ' + response.getBody()
        );
    }
}

private static String stringValue(Object value) {
    return value == null ? null : String.valueOf(value);
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

private static String truncate(String value, Integer maxLength) {
    if (String.isBlank(value)) {
        return null;
    }
    return value.length() <= maxLength ? value : value.substring(0, maxLength);
}

public class QboPaymentSyncException extends Exception {}
}
