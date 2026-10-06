@IsTest
private class QboPaymentSyncJobTest {
    private class EntityMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setHeader('Content-Type', 'application/json');

            if (request.getEndpoint().contains('/payment/900')) {
                response.setBody(
                    '{"Payment":{"Id":"900","Line":[{"Amount":100,"LinkedTxn":[{"TxnId":"145","TxnType":"Invoice"}]}]}}'
                );
            } else if (request.getEndpoint().contains('/invoice/145')) {
                response.setBody(
                    '{"Invoice":{"Id":"145","DocNumber":"SO-00000110","TotalAmt":35000,"Balance":17500,"DueDate":"2026-11-05"}}'
                );
            } else {
                response.setBody('{}');
            }

            return response;
        }
    }

    @IsTest
    static void refreshesInvoiceFromPaymentEvent() {
        Test.setMock(HttpCalloutMock.class, new EntityMock());

        Test.startTest();
        System.enqueueJob(new QboPaymentSyncJob('Payment', '900'));
        Test.stopTest();

        QBO_Sync_Log__c logRecord = [
            SELECT Id, Direction__c, Object_Type__c, Operation__c, Status__c
            FROM QBO_Sync_Log__c
            WHERE Object_Type__c = 'Payment'
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];

        System.assertEquals('Inbound', logRecord.Direction__c);
        System.assertEquals('Webhook Refresh', logRecord.Operation__c);
        System.assertEquals('Success', logRecord.Status__c);
    }

    @IsTest
    static void invoiceEventCanRefreshDirectly() {
        Test.setMock(HttpCalloutMock.class, new EntityMock());

        Test.startTest();
        System.enqueueJob(new QboPaymentSyncJob('Invoice', '145'));
        Test.stopTest();

        QBO_Sync_Log__c logRecord = [
            SELECT Id, Object_Type__c, Status__c
            FROM QBO_Sync_Log__c
            WHERE Object_Type__c = 'Invoice'
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];

        System.assertEquals('Invoice', logRecord.Object_Type__c);
        System.assertEquals('Success', logRecord.Status__c);
    }
}
