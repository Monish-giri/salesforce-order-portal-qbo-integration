@IsTest
private class QboPaymentSyncJobTest {
    private class EntityMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setHeader('Content-Type', 'application/json');

            String endpoint = request.getEndpoint();

            if (endpoint.contains('/query?query=')) {
                response.setBody(
                    '{"QueryResponse":{"Payment":[{"Id":"900","TotalAmt":100,"LineEx":{"any":[{"value":{"Name":"txnId","Value":"145"}}]}}]}}'
                );
            } else if (endpoint.contains('/invoice/145')) {
                response.setBody(
                    '{"Invoice":{"Id":"145","DocNumber":"SO-00000110","TotalAmt":35000,"Balance":19000,"DueDate":"2026-11-05"}}'
                );
            } else {
                response.setBody('{}');
            }

            return response;
        }
    }

    @IsTest
    static void refreshesInvoiceFromPaymentEventAndUpdatesOrder() {
        Account account = new Account(
            Name = 'QBO Payment Sync Test Account'
        );
        insert account;

        Order orderRecord = new Order(
            AccountId = account.Id,
            EffectiveDate = Date.today(),
            Status = 'Draft',
            Pricebook2Id = Test.getStandardPricebookId(),
            QBO_Invoice_Id__c = '145',
            Invoice_Status__c = 'Invoiced',
            Invoice_Total__c = 35000,
            Invoice_Balance__c = 35000,
            Payment_Status__c = 'Unpaid'
        );
        insert orderRecord;

        Test.setMock(HttpCalloutMock.class, new EntityMock());

        Test.startTest();
        System.enqueueJob(new QboPaymentSyncJob('Payment', '900'));
        Test.stopTest();

        Order refreshedOrder = [
            SELECT Id,
                   QBO_Invoice_Id__c,
                   Invoice_Total__c,
                   Invoice_Balance__c,
                   Invoice_Due_Date__c,
                   Payment_Status__c,
                   Last_QBO_Sync__c
            FROM Order
            WHERE Id = :orderRecord.Id
        ];

        System.assertEquals('145', refreshedOrder.QBO_Invoice_Id__c);
        System.assertEquals(35000, refreshedOrder.Invoice_Total__c);
        System.assertEquals(19000, refreshedOrder.Invoice_Balance__c);
        System.assertEquals(Date.newInstance(2026, 11, 5), refreshedOrder.Invoice_Due_Date__c);
        System.assertEquals('Partially Paid', refreshedOrder.Payment_Status__c);
        System.assertNotEquals(null, refreshedOrder.Last_QBO_Sync__c);

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
