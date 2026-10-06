@IsTest
private class OrderInvoiceRequestTriggerTest {
    @IsTest
    static void enqueuesInvoiceJobForOrderEvent() {
        Account account = new Account(
            Name = 'Platform Event Invoice Customer',
            QBO_Customer_Id__c = '60'
        );
        insert account;

        Product2 product = new Product2(
            Name = 'GenWatt Diesel 10kW',
            ProductCode = 'GC1020',
            IsActive = true,
            QBO_Item_Id__c = '19'
        );
        insert product;

        Id pricebookId = Test.getStandardPricebookId();
        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = pricebookId,
            Product2Id = product.Id,
            UnitPrice = 5000,
            IsActive = true
        );
        insert pbe;

        Order order = new Order(
            AccountId = account.Id,
            EffectiveDate = Date.newInstance(2026, 10, 6),
            Status = 'Draft',
            Pricebook2Id = pricebookId
        );
        insert order;

        insert new OrderItem(
            OrderId = order.Id,
            PricebookEntryId = pbe.Id,
            Quantity = 2,
            UnitPrice = 5000
        );

        Test.setMock(HttpCalloutMock.class, new InvoiceCreateMock());

        Test.startTest();
        EventBus.publish(new Order_Invoice_Request__e(
            Order_Id__c = String.valueOf(order.Id)
        ));
        Test.getEventBus().deliver();
        Test.stopTest();

        Order refreshed = [
            SELECT QBO_Invoice_Id__c, Invoice_Status__c
            FROM Order
            WHERE Id = :order.Id
        ];

        System.assertEquals('101', refreshed.QBO_Invoice_Id__c);
        System.assertEquals('Invoiced', refreshed.Invoice_Status__c);
    }

    private class InvoiceCreateMock implements HttpCalloutMock {
        private Integer count = 0;

        public HttpResponse respond(HttpRequest request) {
            count++;

            if (count == 1) {
                System.assertEquals('GET', request.getMethod());
                System.assert(request.getEndpoint().contains('/query?'));
                return response(200, '{"QueryResponse":{}}');
            }

            System.assertEquals(2, count);
            System.assertEquals('POST', request.getMethod());

            Map<String, Object> body =
                (Map<String, Object>) JSON.deserializeUntyped(request.getBody());

            Map<String, Object> customerRef =
                (Map<String, Object>) body.get('CustomerRef');
            System.assertEquals('60', String.valueOf(customerRef.get('value')));

            return response(
                200,
                '{"Invoice":{"Id":"101","DocNumber":"SO-00000103","SyncToken":"0","TxnDate":"2026-10-06","DueDate":"2026-11-05","TotalAmt":10000,"Balance":10000}}'
            );
        }
    }

    private static HttpResponse response(Integer code, String body) {
        HttpResponse r = new HttpResponse();
        r.setStatusCode(code);
        r.setStatus('OK');
        r.setHeader('Content-Type', 'application/json');
        r.setBody(body);
        return r;
    }
}
