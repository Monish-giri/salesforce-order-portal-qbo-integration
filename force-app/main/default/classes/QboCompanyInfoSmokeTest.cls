public with sharing class QboCompanyInfoSmokeTest {
    private static final String NAMED_CREDENTIAL = 'QuickBooks_Sandbox';
    private static final String API_PATH = '/v3/company/{realmId}/companyinfo/{realmId}';

    public class SmokeTestResult {
        public Integer statusCode;
        public String status;
        public String body;
    }

    public class ConfigurationException extends Exception {}

    public static SmokeTestResult run() {
        QBO_Config__mdt config = QBO_Config__mdt.getInstance('Default');

        if (config == null || String.isBlank(config.Realm_Id__c)) {
            throw new ConfigurationException('QBO_Config__mdt Default record is missing Realm_Id__c.');
        }

        if (String.isBlank(config.Minor_Version__c)) {
            throw new ConfigurationException('QBO_Config__mdt Default record is missing Minor_Version__c.');
        }

        String realmId = config.Realm_Id__c.trim();
        String endpoint = 'callout:' + NAMED_CREDENTIAL
            + API_PATH.replace('{realmId}', EncodingUtil.urlEncode(realmId, 'UTF-8'))
            + '?minorversion='
            + EncodingUtil.urlEncode(config.Minor_Version__c.trim(), 'UTF-8');

        HttpRequest request = new HttpRequest();
        request.setEndpoint(endpoint);
        request.setMethod('GET');
        request.setHeader('Accept', 'application/json');
        request.setTimeout(20000);

        HttpResponse response = new Http().send(request);

        SmokeTestResult result = new SmokeTestResult();
        result.statusCode = response.getStatusCode();
        result.status = response.getStatus();
        result.body = response.getBody();
        return result;
    }
}
