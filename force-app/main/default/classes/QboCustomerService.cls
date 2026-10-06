public without sharing class QboCustomerService {
    private static final String NAMED_CREDENTIAL = 'QuickBooks_Sandbox';
    private static final String CUSTOMER_PATH = '/v3/company/{realmId}/customer';
    private static final String QUERY_PATH = '/v3/company/{realmId}/query';

    public class QboCustomerException extends Exception {}

    public static String ensureCustomer(Id accountId) {
        if (accountId == null) {
            throw new QboCustomerException('Account Id is required.');
        }

        Account account = [
            SELECT Id, Name, QBO_Customer_Id__c, Partner_Account__c
            FROM Account
            WHERE Id = :accountId
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        if (String.isNotBlank(account.QBO_Customer_Id__c)) {
            return account.QBO_Customer_Id__c;
        }

        String parentQboId;
        if (account.Partner_Account__c != null) {
            parentQboId = ensureCustomer(account.Partner_Account__c);
        }

        QBO_Config__mdt config = getConfig();
        String displayName = buildDisplayName(account);

        String existingId = findCustomerId(config, displayName);
        if (String.isBlank(existingId)) {
            existingId = createCustomer(config, account, displayName, parentQboId);
        }

        Account updateAccount = new Account(
            Id = account.Id,
            QBO_Customer_Id__c = existingId
        );

        Database.SaveResult saveResult = Database.update(
            updateAccount,
            AccessLevel.SYSTEM_MODE
        );

        if (!saveResult.isSuccess()) {
            throw new QboCustomerException(saveResult.getErrors()[0].getMessage());
        }

        return existingId;
    }

    @TestVisible
    private static String buildDisplayName(Account account) {
        String name = String.isBlank(account.Name) ? 'Salesforce Account' : account.Name.trim();
        String suffix = String.valueOf(account.Id);
        if (suffix.length() > 6) {
            suffix = suffix.substring(suffix.length() - 6);
        }
        return name + ' (SF-' + suffix + ')';
    }

    private static QBO_Config__mdt getConfig() {
        QBO_Config__mdt config = QBO_Config__mdt.getInstance('Default');

        if (config == null || String.isBlank(config.Realm_Id__c)) {
            throw new QboCustomerException(
                'QBO_Config__mdt Default record is missing Realm_Id__c.'
            );
        }

        if (String.isBlank(config.Minor_Version__c)) {
            throw new QboCustomerException(
                'QBO_Config__mdt Default record is missing Minor_Version__c.'
            );
        }

        return config;
    }

    private static String findCustomerId(QBO_Config__mdt config, String displayName) {
        String realmId = config.Realm_Id__c.trim();
        String query = 'select Id, DisplayName from Customer where DisplayName = \''
            + String.escapeSingleQuotes(displayName)
            + '\' maxresults 1';

        HttpRequest request = new HttpRequest();
        request.setEndpoint(
            'callout:' + NAMED_CREDENTIAL
            + QUERY_PATH.replace(
                '{realmId}',
                EncodingUtil.urlEncode(realmId, 'UTF-8')
            )
            + '?minorversion='
            + EncodingUtil.urlEncode(config.Minor_Version__c.trim(), 'UTF-8')
            + '&query='
            + EncodingUtil.urlEncode(query, 'UTF-8')
        );
        request.setMethod('GET');
        request.setHeader('Accept', 'application/json');
        request.setTimeout(20000);

        HttpResponse response = new Http().send(request);
        assertSuccess(response, 'QBO customer query');

        Map<String, Object> payload = parseObject(response.getBody());
        Map<String, Object> queryResponse =
            (Map<String, Object>) payload.get('QueryResponse');

        if (queryResponse == null || !queryResponse.containsKey('Customer')) {
            return null;
        }

        List<Object> customers = (List<Object>) queryResponse.get('Customer');
        if (customers == null || customers.isEmpty()) {
            return null;
        }

        Map<String, Object> customer = (Map<String, Object>) customers[0];
        return customer.containsKey('Id') ? String.valueOf(customer.get('Id')) : null;
    }

    private static String createCustomer(
        QBO_Config__mdt config,
        Account account,
        String displayName,
        String parentQboId
    ) {
        String realmId = config.Realm_Id__c.trim();

        Map<String, Object> payload = new Map<String, Object>{
            'DisplayName' => displayName,
            'CompanyName' => account.Name
        };

        if (String.isNotBlank(parentQboId)) {
            payload.put('ParentRef', new Map<String, Object>{
                'value' => parentQboId
            });
            payload.put('Job', true);
            payload.put('BillWithParent', false);
        }

        HttpRequest request = new HttpRequest();
        request.setEndpoint(
            'callout:' + NAMED_CREDENTIAL
            + CUSTOMER_PATH.replace(
                '{realmId}',
                EncodingUtil.urlEncode(realmId, 'UTF-8')
            )
            + '?minorversion='
            + EncodingUtil.urlEncode(config.Minor_Version__c.trim(), 'UTF-8')
        );
        request.setMethod('POST');
        request.setHeader('Accept', 'application/json');
        request.setHeader('Content-Type', 'application/json');
        request.setTimeout(20000);
        request.setBody(JSON.serialize(payload));

        HttpResponse response = new Http().send(request);
        assertSuccess(response, 'QBO customer creation');

        Map<String, Object> responsePayload = parseObject(response.getBody());
        Map<String, Object> customer =
            (Map<String, Object>) responsePayload.get('Customer');

        if (customer == null || !customer.containsKey('Id')) {
            throw new QboCustomerException(
                'QBO customer creation succeeded but returned no Customer Id.'
            );
        }

        return String.valueOf(customer.get('Id'));
    }

    private static Map<String, Object> parseObject(String body) {
        if (String.isBlank(body)) {
            throw new QboCustomerException('QBO returned an empty response.');
        }

        try {
            return (Map<String, Object>) JSON.deserializeUntyped(body);
        } catch (Exception ex) {
            throw new QboCustomerException('QBO returned invalid JSON.');
        }
    }

    private static void assertSuccess(HttpResponse response, String operation) {
        Integer statusCode = response.getStatusCode();
        if (statusCode < 200 || statusCode >= 300) {
            throw new QboCustomerException(
                operation + ' failed (' + statusCode + '): ' + response.getBody()
            );
        }
    }
}