@IsTest
private class QboWebhookResourceTest {
    private class InvoiceMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setHeader('Content-Type', 'application/json');

            if (request.getEndpoint().contains('/invoice/145')) {
                response.setBody(
                    '{"Invoice":{"Id":"145","DocNumber":"SO-00000110","TotalAmt":35000,"Balance":0,"DueDate":"2026-11-05"}}'
                );
            } else {
                response.setBody('{"QueryResponse":{}}');
            }

            return response;
        }
    }

    @IsTest
    static void acceptsValidSignatureAndQueuesRefresh() {
        String token = 'test-verifier-token';
        String body = '{"eventNotifications":[{"realmId":"123","dataChangeEvent":{"entities":[{"name":"Invoice","id":"145","operation":"Update","lastUpdated":"2026-10-06T10:00:00Z"}]}}]}';

        QboWebhookResource.verifierTokenOverride = token;
        Blob rawBody = Blob.valueOf(body);
        String signature = EncodingUtil.base64Encode(
            Crypto.generateMac('HmacSHA256', rawBody, Blob.valueOf(token))
        );

        RestRequest request = new RestRequest();
        request.httpMethod = 'POST';
        request.requestBody = rawBody;
        request.addHeader('intuit-signature', signature);

        RestResponse response = new RestResponse();
        RestContext.request = request;
        RestContext.response = response;

        Test.setMock(HttpCalloutMock.class, new InvoiceMock());

        Test.startTest();
        QboWebhookResource.handle();
        Test.stopTest();

        System.assertEquals(200, response.statusCode);
        System.assertEquals('{"status":"accepted"}', response.responseBody.toString());

        List<QBO_Sync_Log__c> logs = [
            SELECT Id, Direction__c, Object_Type__c, Operation__c, Status__c
            FROM QBO_Sync_Log__c
            WHERE Direction__c = 'Inbound'
            ORDER BY CreatedDate DESC
            LIMIT 2
        ];

        System.assert(!logs.isEmpty());
        System.assertEquals('Inbound', logs[0].Direction__c);
    }

    @IsTest
    static void rejectsInvalidSignature() {
        QboWebhookResource.verifierTokenOverride = 'test-verifier-token';

        RestRequest request = new RestRequest();
        request.httpMethod = 'POST';
        request.requestBody = Blob.valueOf('{"eventNotifications":[]}');
        request.addHeader('intuit-signature', 'invalid');

        RestResponse response = new RestResponse();
        RestContext.request = request;
        RestContext.response = response;

        Test.startTest();
        QboWebhookResource.handle();
        Test.stopTest();

        System.assertEquals(401, response.statusCode);
        System.assertEquals('{"error":"Invalid signature"}', response.responseBody.toString());
    }
}
